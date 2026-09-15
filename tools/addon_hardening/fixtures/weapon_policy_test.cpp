#include "protocol/wpn_sent_baselines.h"
#include "protocol/wpn_protocol_compat.h"
#include "protocol/wpn_protocol_codec.h"
#include "core/wpn_bytes.h"
#include "core/wpn_version.h"
#include <iostream>
#include <string>
using namespace wpn;
using namespace wpn::protocol;
int main() {
    int checks=0, failures=0;
    auto check = [&](bool ok, const char *why) { ++checks; if (!ok) { ++failures; std::cerr << why << '\n'; } };
    CompatibilityHandshake good;
    good.manifest = compatibility_manifest(123);
    std::uint64_t missing = 0;
    check(check_handshake_compatibility(good, good, missing).ok(), "same sealed manifest");
    for (int field=0; field<7; ++field) {
        auto bad=good;
        if (field==0) ++bad.protocol_version;
        if (field==1) ++bad.manifest.api_major;
        if (field==2) ++bad.manifest.protocol;
        if (field==3) ++bad.manifest.resource_schema;
        if (field==4) ++bad.manifest.catalog_fingerprint;
        if (field==5) ++bad.manifest.world_quantization_version;
        if (field==6) ++bad.manifest.world_tie_rule_version;
        check(!check_handshake_compatibility(good,bad,missing).ok(), "different required manifest field");
    }
    ByteWriter writer(MAX_COMMAND_BYTES);
    check(encode_compatibility_handshake(good,writer).ok(), "handshake encode");
    const auto bytes=writer.bytes();
    for (std::size_t n=0;n<bytes.size();++n) {
        std::vector<std::uint8_t> shortened(bytes.begin(),bytes.begin()+n);
        ByteReader reader(shortened); CompatibilityHandshake decoded;
        check(!decode_compatibility_handshake(reader,decoded).ok(), "truncation rejected");
    }
    auto extra=bytes;extra.push_back(0);
    ByteReader trailing(extra);CompatibilityHandshake decoded;
    check(!decode_compatibility_handshake(trailing,decoded).ok(), "trailing bytes rejected");
    WeaponOwnershipTable owners;
    check(!owners.validate_session(10,1).ok(), "unadmitted peer denied");
    check(owners.begin_session(10,1,1).ok(), "session begins");
    check(!owners.is_compatibility_ready(10), "session starts content closed");
    owners.mark_compatibility_ready(10);
    check(owners.authorize_instance(10,"test.weapon",WeaponRole::OBSERVER).ok(), "observer grant");
    check(!owners.validate_binding(10,"test.weapon",WeaponRole::OWNER).ok(), "observer cannot mutate");
    owners.begin_session(10,2,2);
    check(!owners.is_compatibility_ready(10), "replacement session requires new compatibility");
    check(!owners.validate_connection_epoch(10,1).ok(), "old epoch rejected");
    SentBaselines sent;
    check(!sent.record(0,"test.weapon",1), "no zero peer");
    check(!sent.record(1,"",1), "no empty identity");
    check(!sent.contains(10,"test.weapon",1), "not sent is not ackable");
    check(sent.record(10,"test.weapon",1), "baseline recorded");
    check(sent.contains(10,"test.weapon",1), "exact baseline present");
    check(!sent.contains(10,"test.weapon",2), "future ack rejected");
    check(!sent.contains(11,"test.weapon",1), "another recipient denied");
    check(!sent.contains(10,"other.weapon",1), "another instance denied");
    for (std::uint64_t i=2;i<=100;++i) sent.record(10,"test.weapon",i);
    check(!sent.contains(10,"test.weapon",1), "old ack history evicted");
    check(sent.contains(10,"test.weapon",100), "new baseline retained");
    sent.drop_peer(10);
    check(sent.size()==0 && !sent.contains(10,"test.weapon",100), "revocation releases evidence");
    for (std::size_t i=0;i<MAX_TRACKED_COMMAND_STATES;++i)
        check(sent.record(10,"test.w"+std::to_string(i),i), "bounded baseline admission");
    check(!sent.record(11,"overflow",1), "full ledger rejects rather than evicts live evidence");
    check(sent.size()==MAX_TRACKED_COMMAND_STATES, "ledger hard bound");
    std::cout << "ADDON_POLICY_RESULT checks=" << checks << " failures=" << failures << '\n';
    return failures?1:0;
}
