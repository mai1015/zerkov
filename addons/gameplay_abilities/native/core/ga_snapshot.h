#ifndef GAMEPLAY_ABILITIES_CORE_SNAPSHOT_H
#define GAMEPLAY_ABILITIES_CORE_SNAPSHOT_H

#include "core/ga_bytes.h"
#include "core/ga_fixed.h"
#include "core/ga_hash.h"
#include "core/ga_limits.h"
#include "core/ga_status.h"

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

// Shared canonical-snapshot plumbing every subsystem (tags, attributes,
// effects, abilities) builds its own snapshot encoding on top of.
//
// `SnapshotWriter` wraps a `ByteWriter` and a `Hasher` so that every field a
// subsystem writes is simultaneously encoded into canonical bytes AND folded
// into a running digest -- callers never hash a byte the writer did not also
// serialize, and vice versa. `SnapshotReader` is the matching decoder: it
// validates section framing explicitly and fails closed (see below) rather
// than guessing at a malformed or mismatched payload, and it recomputes the
// identical digest as it decodes so a caller can verify the bytes it just
// parsed are exactly the bytes that were hashed when they were written.
//
// Two components that reached equivalent state through different mutation
// histories MUST serialize to identical bytes and hash to an identical
// digest (see the ordering rule in the shared contract) -- that property is
// this file's entire reason to exist.
namespace ga {

// Addon-internal bound on section nesting depth. Not part of the wire
// format (depth is implicit in matched begin/end calls, never encoded), just
// a guard against unbounded recursion while building a snapshot.
constexpr std::size_t MAX_SNAPSHOT_SECTION_DEPTH = 8;

class SnapshotWriter {
public:
	explicit SnapshotWriter(std::size_t p_byte_limit = MAX_SNAPSHOT_BYTES) :
			root(p_byte_limit), byte_limit(p_byte_limit) {}

	// Opens a section tagged `p_kind`. Sections may nest up to
	// `MAX_SNAPSHOT_SECTION_DEPTH`. Every write between `begin_section` and
	// its matching `end_section` is buffered so `end_section` can prefix it
	// with a self-describing (kind, length) header once the length is
	// known.
	bool begin_section(std::uint8_t p_kind);

	// Closes the most recently opened section: writes its (kind, length)
	// header followed by its buffered payload into the enclosing scope (or
	// the root), and folds the header into the running digest (the payload
	// bytes were already folded in as they were written).
	bool end_section();

	void write_u8(std::uint8_t p_value);
	void write_u16(std::uint16_t p_value);
	void write_u32(std::uint32_t p_value);
	void write_u64(std::uint64_t p_value);
	void write_i32(std::int32_t p_value);
	void write_i64(std::int64_t p_value);
	void write_bool(bool p_value);
	void write_string(const std::string &p_value);
	void write_fixed(Fixed p_value);

	// Fails closed (marks the writer failed) if `p_count` exceeds `p_limit`
	// or `MAX_COLLECTION_COUNT`, mirroring `ByteWriter::write_count`.
	void write_count(std::size_t p_count, std::size_t p_limit);

	bool ok() const { return manually_ok && root.ok(); }
	Status status() const { return manually_ok ? root.status() : manual_status; }

	// Total root-level bytes written so far. Only meaningful once every
	// opened section has a matching `end_section` -- section payloads are
	// not flushed into the root buffer until then.
	std::size_t size() const { return root.size(); }

	// Takes the final byte buffer. Callers should only call this once
	// `stack` is empty (every section closed); an unbalanced call still
	// returns whatever the root buffer holds; use `ok()` to check.
	std::vector<std::uint8_t> take() { return root.take(); }

	// Running FNV1a64 digest over every field written, including section
	// (kind, length) framing, in the exact order it was written.
	std::uint64_t digest() const { return hasher.digest(); }

private:
	struct Scope {
		std::uint8_t kind = 0;
		ByteWriter buffer;
	};

	ByteWriter &current() { return stack.empty() ? root : stack.back().buffer; }
	void mark_failed(StatusCode p_code, DiagnosticId p_diagnostic, std::uint64_t p_detail) {
		if (manually_ok) {
			manually_ok = false;
			manual_status = make_status(p_code, p_diagnostic, p_detail);
		}
	}

	std::vector<Scope> stack;
	ByteWriter root;
	Hasher hasher;
	std::size_t byte_limit = MAX_SNAPSHOT_BYTES;
	bool manually_ok = true;
	Status manual_status;
};

class SnapshotReader {
public:
	explicit SnapshotReader(const std::vector<std::uint8_t> &p_bytes) :
			reader(p_bytes) {}
	SnapshotReader(const std::uint8_t *p_data, std::size_t p_size) :
			reader(p_data, p_size) {}

	// Reads a section header and validates it against `p_expected_kind`.
	// Fails closed if the encoded kind differs from `p_expected_kind`, or if
	// the encoded length exceeds the bytes actually remaining -- a
	// mismatched section is never silently skipped or reinterpreted as
	// something else.
	bool begin_section(std::uint8_t p_expected_kind);

	// Confirms every byte declared by the matching `begin_section` was
	// consumed by the reads in between -- not more, not fewer. Fails closed
	// on a mismatch (a partially-read or over-read section indicates a
	// schema mismatch, not a benign gap).
	bool end_section();

	bool read_u8(std::uint8_t &r_value);
	bool read_u16(std::uint16_t &r_value);
	bool read_u32(std::uint32_t &r_value);
	bool read_u64(std::uint64_t &r_value);
	bool read_i32(std::int32_t &r_value);
	bool read_i64(std::int64_t &r_value);
	bool read_bool(bool &r_value);
	bool read_string(std::string &r_value);
	bool read_fixed(Fixed &r_value);
	bool read_count(std::size_t &r_count, std::size_t p_limit, std::size_t p_min_bytes_per_element = 1);

	bool ok() const { return manual_status.ok() && reader.ok(); }
	Status status() const { return !manual_status.ok() ? manual_status : reader.status(); }

	// True once every opened section has a matching `end_section` and no
	// bytes remain.
	bool at_end() const { return ok() && stack.empty() && reader.at_end(); }

	// Running FNV1a64 digest over every field read (including section
	// framing), computed with the identical sequence `SnapshotWriter` used
	// so a caller can compare it against an expected fingerprint without a
	// separate re-hash of the raw bytes.
	std::uint64_t digest() const { return hasher.digest(); }

private:
	struct Bound {
		std::size_t end_cursor = 0;
		std::uint32_t length = 0;
	};

	bool fail(StatusCode p_code, DiagnosticId p_diagnostic, std::uint64_t p_detail) {
		if (manual_status.ok()) {
			manual_status = make_status(p_code, p_diagnostic, p_detail);
		}
		return false;
	}

	// Verifies the most recent read did not consume past the innermost open
	// section's declared boundary; fails closed if it did.
	bool check_bound() {
		if (!stack.empty() && reader.consumed() > stack.back().end_cursor) {
			return fail(StatusCode::DECODE_FAILED, DiagnosticId::TRUNCATED_PAYLOAD, reader.consumed());
		}
		return true;
	}

	std::vector<Bound> stack;
	ByteReader reader;
	Hasher hasher;
	Status manual_status;
};

} // namespace ga

#endif // GAMEPLAY_ABILITIES_CORE_SNAPSHOT_H
