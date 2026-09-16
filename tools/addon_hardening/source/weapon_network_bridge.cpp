#include "godot/weapon_network_bridge.h"
#include "godot/weapon_authority.h"
#include "core/wpn_bytes.h"
#include "core/wpn_hash.h"
#include "core/wpn_identifier.h"
#include "core/wpn_version.h"
#include "protocol/wpn_protocol_codec.h"
#include "protocol/wpn_protocol_compat.h"
#include <godot_cpp/classes/crypto.hpp>
#include <godot_cpp/classes/multiplayer_peer.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <algorithm>
#include <limits>

namespace godot {
namespace {
std::string text(const String &v) { return v.utf8().get_data(); }
PackedByteArray packed(const std::vector<uint8_t> &v) {
 PackedByteArray out; out.resize(int64_t(v.size()));
 for (size_t i=0;i<v.size();++i) out.set(int64_t(i),v[i]);
 return out;
}
Dictionary status_dict(const wpn::Status &s) {
 Dictionary d; d["ok"]=s.ok(); d["code"]=int(s.code); d["diagnostic"]=int(s.diagnostic); d["detail"]=int64_t(s.detail); return d;
}
wpn::Status denied() { return wpn::make_status(wpn::StatusCode::PERMISSION_DENIED); }
Dictionary point(const wpn::FixedVec2 &v) { Dictionary d; d["x"]=v.x; d["y"]=v.y; return d; }
wpn::FixedVec2 from_point(const Variant &v) {
 if (v.get_type()!=Variant::DICTIONARY) return {};
 Dictionary d=v; return {int64_t(d.get("x",int64_t(0))),int64_t(d.get("y",int64_t(0)))};
}
uint64_t positive(const Variant &v) { return v.get_type()==Variant::INT && int64_t(v)>=0 ? uint64_t(int64_t(v)) : 0; }
}
WeaponAuthority *WeaponNetworkBridge::authority() const {
 return weapon_authority_path.is_empty() ? nullptr : Object::cast_to<WeaponAuthority>(get_node_or_null(weapon_authority_path));
}
bool WeaponNetworkBridge::local_manifest(wpn::protocol::CompatibilityHandshake &value) const {
 if (role==ROLE_SERVER) {
  auto *a=authority(); if (!a || !a->is_ready()) return false;
  value.manifest=wpn::compatibility_manifest(uint64_t(a->content_fingerprint()));
 } else {
  if (!client_catalog_set) return false;
  value.manifest=wpn::compatibility_manifest(client_catalog);
 }
 return true;
}
void WeaponNetworkBridge::set_client_catalog_fingerprint(int64_t value) {
 if (role!=ROLE_CLIENT) return;
 if (client_catalog_set && client_catalog!=uint64_t(value)) clear_client();
 client_catalog=uint64_t(value); client_catalog_set=true;
}
bool WeaponNetworkBridge::is_multiplayer_active() const {
 const auto api=get_multiplayer(); return api.is_valid() && api->has_multiplayer_peer() && !api->get_peers().is_empty();
}
bool WeaponNetworkBridge::server_sender() const {
 const auto api=get_multiplayer(); return role==ROLE_CLIENT && api.is_valid() && api->get_remote_sender_id()==server_peer_id;
}
void WeaponNetworkBridge::_ready() {
 Dictionary inbound; inbound["rpc_mode"]=MultiplayerAPI::RPC_MODE_ANY_PEER; inbound["call_local"]=false;
 inbound["transfer_mode"]=MultiplayerPeer::TRANSFER_MODE_RELIABLE; inbound["channel"]=0;
 Dictionary outbound=inbound.duplicate(); outbound["rpc_mode"]=MultiplayerAPI::RPC_MODE_AUTHORITY;
 for (const char *name : {"_rpc_request_offer","_rpc_compatibility_handshake","_rpc_fire_intent","_rpc_begin_reload_intent",
   "_rpc_cancel_reload_intent","_rpc_configure_attachments_intent","_rpc_acknowledgement_batch","_rpc_resync_request"}) rpc_config(name,inbound);
 for (const char *name : {"_rpc_session_offer","_rpc_session_ready","_rpc_session_closed","_rpc_instance_revoked",
   "_rpc_snapshot_batch","_rpc_delta_batch","_rpc_command_rejection","_rpc_command_result"}) rpc_config(name,outbound);
 set_multiplayer_authority(server_peer_id);
 wired_api=get_multiplayer();
 if (wired_api.is_valid()) {
  wired_api->connect("peer_disconnected",callable_mp(this,&WeaponNetworkBridge::on_peer_disconnected));
  if (role==ROLE_CLIENT) wired_api->connect("server_disconnected",callable_mp(this,&WeaponNetworkBridge::on_server_disconnected));
 }
 if (role==ROLE_CLIENT) clear_client();
}
void WeaponNetworkBridge::_exit_tree() {
 if (wired_api.is_valid()) {
  auto disconnected=callable_mp(this,&WeaponNetworkBridge::on_peer_disconnected);
  if (wired_api->is_connected("peer_disconnected",disconnected)) wired_api->disconnect("peer_disconnected",disconnected);
  auto server=callable_mp(this,&WeaponNetworkBridge::on_server_disconnected);
  if (wired_api->is_connected("server_disconnected",server)) wired_api->disconnect("server_disconnected",server);
 }
 wired_api.unref(); sessions.clear(); pending.clear(); clear_client();
}
void WeaponNetworkBridge::_process(double delta) {
 if (role!=ROLE_CLIENT || !prediction) return;
 const double bounded=std::clamp(delta,0.0,1.0);
 if (!client_ready && is_multiplayer_active() && client_catalog_set) {
  handshake_retry+=bounded;
  if (handshake_retry>=1.0) { handshake_retry=0; send_compatibility_handshake(); }
 }
 advisory_ticks+=bounded*double(tick_rate);
 const uint64_t elapsed=uint64_t(advisory_ticks); advisory_ticks-=double(elapsed); tick+=elapsed;
 for (const auto &outcome: prediction->sweep_expired(tick))
  emit_signal("presentation_expired",String(outcome.intent.command_id.c_str()),String(outcome.intent.instance_id.c_str()),int(outcome.intent.kind));
}
void WeaponNetworkBridge::clear_client() {
 // No old-session confirmed or pending state remains readable after disconnect.
 if (prediction) for (const auto &entry:client_sequences)
  for (const auto &outcome:prediction->diverge_instance(text(entry.first)))
   emit_signal("presentation_expired",String(outcome.intent.command_id.c_str()),entry.first,int(outcome.intent.kind));
 replica=std::make_unique<wpn::protocol::WeaponReplica>();
 prediction=std::make_unique<wpn::protocol::PresentationPredictionTracker>();
 client_sequences.clear(); local_counter=0; client_ready=false; client_token.clear(); tick=0; advisory_ticks=0; handshake_retry=0;
}
void WeaponNetworkBridge::on_peer_disconnected(int peer) {
 if (role==ROLE_SERVER) drop_peer(peer); else if(peer==server_peer_id) clear_client();
}
void WeaponNetworkBridge::on_server_disconnected() { if(role==ROLE_CLIENT) clear_client(); }
PackedByteArray WeaponNetworkBridge::pack(const PackedByteArray &token,const std::vector<uint8_t> &bytes) {
 if(token.size()!=TOKEN_BYTES) return {};
 PackedByteArray out; out.resize(HEADER_BYTES+int64_t(bytes.size()));
 out.set(0,'W');out.set(1,'N');out.set(2,'B');out.set(3,1);
 for(int i=0;i<TOKEN_BYTES;++i) out.set(4+i,token[i]);
 for(size_t i=0;i<bytes.size();++i) out.set(HEADER_BYTES+int64_t(i),bytes[i]);
 return out;
}
bool WeaponNetworkBridge::unpack(const PackedByteArray &wire,const PackedByteArray &token,size_t maximum,std::vector<uint8_t> &bytes) {
 if(token.size()!=TOKEN_BYTES || wire.size()<HEADER_BYTES || uint64_t(wire.size())>maximum+HEADER_BYTES
   || wire[0]!='W'||wire[1]!='N'||wire[2]!='B'||wire[3]!=1) return false;
 for(int i=0;i<TOKEN_BYTES;++i) if(wire[4+i]!=token[i]) return false;
 bytes.resize(size_t(wire.size()-HEADER_BYTES));
 for(size_t i=0;i<bytes.size();++i) bytes[i]=wire[HEADER_BYTES+int64_t(i)];
 return true;
}
bool WeaponNetworkBridge::unpack_client(const PackedByteArray &wire,size_t maximum,int &peer,std::vector<uint8_t> &bytes,bool require_ready) {
 if(role!=ROLE_SERVER || in_admission) return false;
 auto api=get_multiplayer(); peer=api.is_valid()?api->get_remote_sender_id():0;
 auto it=sessions.find(peer);
 if(peer<=0 || it==sessions.end() || (require_ready && !it->second->ready)) return false;
 // Rate budget precedes copying/decoding, including malformed and auxiliary RPCs.
 if(!rate.admit_command(peer,tick,uint32_t(tick_rate)).ok()) return false;
 if (!unpack(wire,it->second->token,maximum,bytes) || bytes.size()<2) return false;
 // Session compatibility does not authorize a different DTO protocol version.
 return (uint16_t(bytes[0]) | (uint16_t(bytes[1]) << 8)) == wpn::PROTOCOL_VERSION;
}
bool WeaponNetworkBridge::unpack_server(const PackedByteArray &wire,size_t maximum,std::vector<uint8_t> &bytes) const {
 return server_sender() && client_ready && unpack(wire,client_token,maximum,bytes);
}
void WeaponNetworkBridge::begin_session(int peer,int64_t session) {
 if(role!=ROLE_SERVER || in_admission || peer<=0 || session<=0 || (sessions.size()>=MAX_PEERS && !sessions.count(peer))) return;
 auto api=get_multiplayer(); if(!api.is_valid() || !api->get_peers().has(peer)) return;
 wpn::protocol::CompatibilityHandshake manifest; if(!local_manifest(manifest)) return;
 Ref<Crypto> crypto; crypto.instantiate(); if(crypto.is_null()) return;
 auto token=crypto->generate_random_bytes(TOKEN_BYTES); if(token.size()!=TOKEN_BYTES) return;
 drop_peer(peer); // Fresh connection never inherits grants, readiness or ack state.
 auto value=std::make_shared<Session>(); value->id=uint64_t(session);value->epoch=++epoch_counter;
 value->catalog=manifest.manifest.catalog_fingerprint;value->token=token;sessions[peer]=value;
 send_offer(peer);
}
void WeaponNetworkBridge::drop_peer(int peer) {
 if(role!=ROLE_SERVER || in_admission) return;
 auto it=sessions.find(peer);
 if(it!=sessions.end()) {
  const auto api=get_multiplayer();
  if(api.is_valid()&&api->get_peers().has(peer)) rpc_id(peer,"_rpc_session_closed",it->second->token);
  sessions.erase(it);
 }
 for(auto itp=pending.begin();itp!=pending.end();) {if(itp->second.peer==peer) itp=pending.erase(itp);else ++itp;}
 rate.drop_peer(peer);
}
void WeaponNetworkBridge::end_session(int peer) { drop_peer(peer); }
Dictionary WeaponNetworkBridge::peer_state(int peer) const {
 Dictionary out; auto it=sessions.find(peer); out["ready"]=it!=sessions.end()&&it->second->ready;
 out["tracked_peers"]=int64_t(sessions.size());out["pending_commands"]=int64_t(pending.size());
 if(it!=sessions.end()) {out["epoch"]=int64_t(it->second->epoch);out["grants"]=int64_t(it->second->grants.size());
  Dictionary acks; for(const auto &entry:it->second->acked) acks[entry.first]=int64_t(entry.second);out["acknowledged"]=acks;}
 return out;
}
bool WeaponNetworkBridge::recipient_ready(int peer,const String &instance,int permission) const {
 if(role!=ROLE_SERVER) return false;
 auto it=sessions.find(peer);if(it==sessions.end()||!it->second->ready) return false;
 auto grant=it->second->grants.find(instance);if(grant==it->second->grants.end()||grant->second<permission) return false;
 auto *a=authority();return a&&a->is_ready()&&uint64_t(a->content_fingerprint())==it->second->catalog;
}
bool WeaponNetworkBridge::authorize_instance(int peer,const String &instance,int permission) {
 if(role!=ROLE_SERVER||in_admission||!sessions.count(peer)||(permission!=0&&permission!=1)||!wpn::validate_identifier(text(instance)).ok()) return false;
 auto session=sessions.at(peer);
 if(session->grants.size()>=wpn::MAX_BOUND_INSTANCES_PER_PEER&&!session->grants.count(instance))return false;
 // Replacing a grant invalidates queued work under the old grant. Preserve a
 // terminal denial in the replay cache: an admitted-but-cancelled request must
 // never later replay as successful execution merely because pending was erased.
 for(auto it=pending.begin();it!=pending.end();) {
  if(it->second.peer==peer&&it->second.instance==instance) {
   const auto old=it->second;
   session->sequence.record(text(instance),text(old.client_id),old.sequence,old.payload_hash,denied());
   it=pending.erase(it);
  } else ++it;
 }
 session->grants[instance]=permission;session->acked.erase(instance);session->sent.erase(instance);
 send_state(peer,instance,true);return true;
}
bool WeaponNetworkBridge::revoke_instance(int peer,const String &instance) {
 if(role!=ROLE_SERVER||in_admission||!sessions.count(peer)) return false;
 auto s=sessions.at(peer);if(!s->grants.erase(instance))return false;
 s->acked.erase(instance);s->sent.erase(instance);
 for(auto it=pending.begin();it!=pending.end();) {
  if(it->second.peer==peer&&it->second.instance==instance) {
   const auto old=it->second;
   s->sequence.record(text(instance),text(old.client_id),old.sequence,old.payload_hash,denied());
   it=pending.erase(it);
  } else ++it;
 }
 auto bytes=instance.to_utf8_buffer();std::vector<uint8_t> value(bytes.ptr(),bytes.ptr()+bytes.size());
 rpc_id(peer,"_rpc_instance_revoked",pack(s->token,value));return true;
}
void WeaponNetworkBridge::send_offer(int peer) {
 if(!sessions.count(peer))return;
 wpn::protocol::CompatibilityHandshake manifest;if(!local_manifest(manifest))return;
 wpn::ByteWriter writer(wpn::MAX_COMMAND_BYTES);
 if(wpn::protocol::encode_compatibility_handshake(manifest,writer).ok())
  rpc_id(peer,"_rpc_session_offer",sessions.at(peer)->token,packed(writer.bytes()));
}
void WeaponNetworkBridge::_rpc_request_offer() {
 if(role!=ROLE_SERVER)return;auto api=get_multiplayer();int peer=api.is_valid()?api->get_remote_sender_id():0;
 if(peer>0&&sessions.count(peer)&&rate.admit_command(peer,tick,uint32_t(tick_rate)).ok())send_offer(peer);
}
void WeaponNetworkBridge::_rpc_session_offer(const PackedByteArray &token,const PackedByteArray &bytes) {
 if(!server_sender()||token.size()!=TOKEN_BYTES||uint64_t(bytes.size())>wpn::MAX_COMMAND_BYTES)return;
 wpn::protocol::CompatibilityHandshake local,remote;if(!local_manifest(local))return;
 wpn::ByteReader reader(bytes.ptr(),size_t(bytes.size()));uint64_t missing=0;
 auto status=wpn::protocol::decode_compatibility_handshake(reader,remote);
 if(status.ok())status=wpn::protocol::check_handshake_compatibility(local,remote,missing);
 if(!status.ok()) {clear_client();emit_signal("network_diagnostic",server_peer_id,status_dict(status));return;}
 if(client_token!=token){clear_client();client_token=token.duplicate();}
 send_compatibility_handshake();
}
void WeaponNetworkBridge::send_compatibility_handshake() {
 if(role!=ROLE_CLIENT||!is_multiplayer_active()||!client_catalog_set)return;
 if(client_token.size()!=TOKEN_BYTES){rpc_id(server_peer_id,"_rpc_request_offer");return;}
 wpn::protocol::CompatibilityHandshake local;if(!local_manifest(local))return;
 wpn::ByteWriter writer(wpn::MAX_COMMAND_BYTES);
 if(wpn::protocol::encode_compatibility_handshake(local,writer).ok())
  rpc_id(server_peer_id,"_rpc_compatibility_handshake",pack(client_token,writer.bytes()));
}
void WeaponNetworkBridge::_rpc_compatibility_handshake(const PackedByteArray &wire) {
 int peer=0;std::vector<uint8_t> bytes;if(!unpack_client(wire,wpn::MAX_COMMAND_BYTES,peer,bytes,false))return;
 auto s=sessions.at(peer);s->ready=false;
 wpn::protocol::CompatibilityHandshake local,remote;uint64_t missing=0;
 if(!local_manifest(local))return;
 wpn::ByteReader reader(bytes);auto status=wpn::protocol::decode_compatibility_handshake(reader,remote);
 if(status.ok())status=wpn::protocol::check_handshake_compatibility(local,remote,missing);
 if(!status.ok()){emit_signal("network_diagnostic",peer,status_dict(status));return;}
 s->ready=true;s->catalog=local.manifest.catalog_fingerprint;
 rpc_id(peer,"_rpc_session_ready",s->token);
 for(const auto &grant:s->grants)send_state(peer,grant.first,true);
}
void WeaponNetworkBridge::_rpc_session_ready(const PackedByteArray &token) {
 if(server_sender()&&token.size()==TOKEN_BYTES&&token==client_token) {client_ready=true;emit_signal("session_ready");}
}
void WeaponNetworkBridge::_rpc_session_closed(const PackedByteArray &token) {
 if(server_sender()&&token==client_token)clear_client();
}
void WeaponNetworkBridge::_rpc_instance_revoked(const PackedByteArray &wire) {
 std::vector<uint8_t> bytes;if(!unpack_server(wire,wpn::MAX_IDENTIFIER_BYTES,bytes))return;
 std::string id(bytes.begin(),bytes.end());if(!wpn::validate_identifier(id).ok())return;
 replica->forget_instance(id);
 for(const auto &outcome:prediction->diverge_instance(id))emit_signal("presentation_diverged",String(outcome.intent.command_id.c_str()),String(id.c_str()),int(outcome.intent.kind));
 emit_signal("instance_revoked",String(id.c_str()));
}
void WeaponNetworkBridge::remember_sent(Session &s,const String &instance,uint64_t revision) {
 auto &sent=s.sent[instance];sent.insert(revision);
 while(sent.size()>64)sent.erase(sent.begin()); // Delayed obsolete acks cause a full resync, never forged progression.
}
void WeaponNetworkBridge::send_state(int peer,const String &instance,bool full) {
 if(!recipient_ready(peer,instance))return;
 auto s=sessions.at(peer);auto *a=authority();auto *snapshot=a->find_snapshot(text(instance));
 auto *tombstone=snapshot?nullptr:a->find_tombstone_value(text(instance));if(!snapshot&&!tombstone)return;
 uint64_t revision=snapshot?snapshot->revision:tombstone->revision;
 auto ack=s->acked.find(instance);
 if(!full&&ack!=s->acked.end()&&ack->second==revision)return;
 if(full||ack==s->acked.end()) {
  wpn::protocol::WeaponSnapshotBatch batch;if(snapshot)batch.snapshots.push_back(*snapshot);else batch.tombstones.push_back(*tombstone);
  wpn::ByteWriter writer(wpn::MAX_SNAPSHOT_BYTES);
  if(wpn::protocol::encode_snapshot_batch(batch,writer).ok()&&rpc_id(peer,"_rpc_snapshot_batch",pack(s->token,writer.bytes()))==OK)remember_sent(*s,instance,revision);
 } else {
  wpn::protocol::WeaponDeltaBatch batch;batch.authority_tick=tick;wpn::protocol::WeaponDelta delta;
  delta.predecessor_revision=ack->second;delta.successor_revision=revision;
  if(snapshot){delta.lifecycle=wpn::protocol::WeaponLifecycleState::ACTIVE;delta.snapshot=*snapshot;}
  else {delta.lifecycle=wpn::protocol::WeaponLifecycleState::TOMBSTONED;delta.tombstone=*tombstone;}
  batch.deltas.push_back(delta);wpn::ByteWriter writer(wpn::MAX_DELTA_BYTES);
  if(wpn::protocol::encode_delta_batch(batch,writer).ok()&&rpc_id(peer,"_rpc_delta_batch",pack(s->token,writer.bytes()))==OK)remember_sent(*s,instance,revision);
 }
}
void WeaponNetworkBridge::push_state(int64_t now) {
 if(role!=ROLE_SERVER||in_admission||now<0||uint64_t(now)<tick)return;
 tick=uint64_t(now);
 for(const auto &session:sessions)for(const auto &grant:session.second->grants)send_state(session.first,grant.first);
}
void WeaponNetworkBridge::replicate_teardown(const String &instance) {
 if(role!=ROLE_SERVER||in_admission)return;
 for(const auto &session:sessions)send_state(session.first,instance);
}
void WeaponNetworkBridge::_rpc_acknowledgement_batch(const PackedByteArray &wire) {
 int peer=0;std::vector<uint8_t> bytes;if(!unpack_client(wire,wpn::MAX_DELTA_BYTES,peer,bytes))return;
 wpn::protocol::AcknowledgementBatch batch;wpn::ByteReader reader(bytes);
 if(!wpn::protocol::decode_acknowledgement_batch(reader,batch).ok())return;
 auto s=sessions.at(peer);
 // Whole batch authorization before mutation. Only an actually sent revision
 // is acknowledgeable; a merely smaller-than-head number is not sufficient.
 for(const auto &ack:batch.acknowledgements){String id(ack.instance_id.c_str());
  if(!recipient_ready(peer,id)||!s->sent.count(id)||!s->sent.at(id).count(ack.acknowledged_revision))return;}
 for(const auto &ack:batch.acknowledgements){String id(ack.instance_id.c_str());auto &value=s->acked[id];
  value=std::max(value,ack.acknowledged_revision);auto &sent=s->sent[id];while(!sent.empty()&&*sent.begin()<value)sent.erase(sent.begin());}
}
void WeaponNetworkBridge::_rpc_resync_request(const PackedByteArray &wire) {
 int peer=0;std::vector<uint8_t> bytes;if(!unpack_client(wire,wpn::MAX_COMMAND_BYTES,peer,bytes))return;
 if(!rate.admit_resync(peer,tick,uint32_t(tick_rate)).ok())return;
 wpn::protocol::ResyncRequest request;wpn::ByteReader reader(bytes);
 if(wpn::protocol::decode_resync_request(reader,request).ok())send_state(peer,String(request.instance_id.c_str()),true);
}
void WeaponNetworkBridge::send_result(int peer,const String &instance,const String &client_id,const wpn::Status &status,bool final) {
 if(!sessions.count(peer)||!sessions.at(peer)->ready)return;
 wpn::protocol::CommandRejection result;result.command_id=text(client_id);result.instance_id=text(instance);result.status=status;
 // Unauthorized requests must not reveal even the hidden instance's revision.
 if(recipient_ready(peer,instance)){auto *snapshot=authority()->find_snapshot(text(instance));if(snapshot)result.current_revision=snapshot->revision;}
 wpn::ByteWriter writer(wpn::MAX_COMMAND_BYTES);
 if(wpn::protocol::encode_command_rejection(result,writer).ok())rpc_id(peer,final?"_rpc_command_result":"_rpc_command_rejection",pack(sessions.at(peer)->token,writer.bytes()));
 if(!status.ok())emit_signal("command_rejected",peer,client_id,instance,status_dict(status));
}
void WeaponNetworkBridge::dispatch(int peer,const String &instance,const String &client_id,uint64_t sequence,const std::vector<uint8_t> &bytes,Dictionary request) {
 if(!recipient_ready(peer,instance,1)||sequence==0||sequence>uint64_t(INT64_MAX)||client_id.is_empty()){send_result(peer,instance,client_id,denied(),false);return;}
 auto session=sessions.at(peer);uint64_t hash=wpn::hash_bytes(bytes);wpn::Status previous;
 auto decision=session->sequence.check(text(instance),text(client_id),sequence,hash,previous);
 String canonical="net."+(session->token.hex_encode()+"|"+instance+"|"+client_id).sha256_text();
 if(decision==wpn::protocol::CommandSequenceTracker::SequenceOutcome::DUPLICATE){
  if(!pending.count(canonical))send_result(peer,instance,client_id,previous,true);
  return;
 }
 if(decision!=wpn::protocol::CommandSequenceTracker::SequenceOutcome::EXECUTE){send_result(peer,instance,client_id,wpn::make_status(wpn::StatusCode::DUPLICATE_CONFLICT),false);return;}
 if(!command_admission_handler.is_valid()||pending.size()>=MAX_PENDING){
  session->sequence.record(text(instance),text(client_id),sequence,hash,denied());send_result(peer,instance,client_id,denied(),false);return;
 }
 request["command_id"]=canonical;request["client_command_id"]=client_id;request["instance_id"]=instance;
 request["peer"]=peer;request["session"]=int64_t(session->id);request["connection_epoch"]=int64_t(session->epoch);
 request["session_key"]=session->token.hex_encode();request["client_sequence"]=int64_t(sequence);
 request["server_tick"]=int64_t(tick);request["authority_scope"]=authority_scope;request["authority_epoch"]=authority_epoch;
 // Client entropy is deliberately absent. Trusted execution assigns its own
 // sampling entropy, canonical sequence and execution tick, and validates inventory.
 pending[canonical]={peer,session,instance,client_id,sequence,hash};
 session->sequence.record(text(instance),text(client_id),sequence,hash,wpn::ok_status());
 in_admission=true;Variant value=command_admission_handler.call(request);in_admission=false;
 if(value.get_type()!=Variant::DICTIONARY||Dictionary(value).get("admitted",Variant()).get_type()!=Variant::BOOL){
  // Admission outcome unknown: do not invent a safe retry or a success receipt.
  drop_peer(peer);return;
 }
 Dictionary result=value;
 if(!bool(result["admitted"])) {pending.erase(canonical);session->sequence.record(text(instance),text(client_id),sequence,hash,denied());send_result(peer,instance,client_id,denied(),false);}
}
bool WeaponNetworkBridge::command_still_current(const String &id) {
 if(role!=ROLE_SERVER||in_admission||!pending.count(id))return false;
 const auto &p=pending.at(id);return sessions.count(p.peer)&&sessions.at(p.peer)==p.session&&recipient_ready(p.peer,p.instance,1);
}
bool WeaponNetworkBridge::complete_command(const String &id,bool accepted) {
 if(!command_still_current(id))return false;
 auto p=pending.at(id);pending.erase(id);auto status=accepted?wpn::ok_status():wpn::make_status(wpn::StatusCode::COMMAND_REJECTED);
 p.session->sequence.record(text(p.instance),text(p.client_id),p.sequence,p.payload_hash,status);
 send_state(p.peer,p.instance);send_result(p.peer,p.instance,p.client_id,status,true);return true;
}
void WeaponNetworkBridge::_rpc_fire_intent(const PackedByteArray &wire) {
 int peer=0;std::vector<uint8_t> bytes;if(!unpack_client(wire,wpn::MAX_COMMAND_BYTES,peer,bytes))return;
 wpn::protocol::FireIntent i;wpn::ByteReader reader(bytes);if(!wpn::protocol::decode_fire_intent(reader,i).ok()||i.expected_revision>uint64_t(INT64_MAX))return;
 Dictionary d;d["kind"]="fire";d["expected_revision"]=int64_t(i.expected_revision);d["claimed_origin"]=point(i.claimed_origin);d["claimed_aim"]=point(i.claimed_aim);
 dispatch(peer,String(i.instance_id.c_str()),String(i.command_id.c_str()),i.sequence,bytes,d);
}
void WeaponNetworkBridge::_rpc_begin_reload_intent(const PackedByteArray &wire) {
 int peer=0;std::vector<uint8_t> bytes;if(!unpack_client(wire,wpn::MAX_COMMAND_BYTES,peer,bytes))return;
 wpn::protocol::BeginReloadIntent i;wpn::ByteReader reader(bytes);if(!wpn::protocol::decode_begin_reload_intent(reader,i).ok()||i.expected_revision>uint64_t(INT64_MAX))return;
 Dictionary d;d["kind"]="begin_reload";d["expected_revision"]=int64_t(i.expected_revision);d["reservation_id"]=String(i.reservation_id.c_str());d["reserved_rounds"]=int64_t(i.reserved_rounds);
 dispatch(peer,String(i.instance_id.c_str()),String(i.command_id.c_str()),i.sequence,bytes,d);
}
void WeaponNetworkBridge::_rpc_cancel_reload_intent(const PackedByteArray &wire) {
 int peer=0;std::vector<uint8_t> bytes;if(!unpack_client(wire,wpn::MAX_COMMAND_BYTES,peer,bytes))return;
 wpn::protocol::CancelReloadIntent i;wpn::ByteReader reader(bytes);if(!wpn::protocol::decode_cancel_reload_intent(reader,i).ok()||i.expected_revision>uint64_t(INT64_MAX))return;
 Dictionary d;d["kind"]="cancel_reload";d["expected_revision"]=int64_t(i.expected_revision);
 dispatch(peer,String(i.instance_id.c_str()),String(i.command_id.c_str()),i.sequence,bytes,d);
}
void WeaponNetworkBridge::_rpc_configure_attachments_intent(const PackedByteArray &wire) {
 int peer=0;std::vector<uint8_t> bytes;if(!unpack_client(wire,wpn::MAX_COMMAND_BYTES,peer,bytes))return;
 wpn::protocol::ConfigureAttachmentsIntent i;wpn::ByteReader reader(bytes);if(!wpn::protocol::decode_configure_attachments_intent(reader,i).ok()||i.expected_revision>uint64_t(INT64_MAX))return;
 Array loadout;for(const auto &a:i.desired_loadout){Dictionary e;e["slot_id"]=String(a.slot_id.c_str());e["attachment_id"]=String(a.attachment_id.c_str());e["attachment_version"]=int(a.attachment_version);loadout.append(e);}
 Dictionary d;d["kind"]="configure_attachments";d["expected_revision"]=int64_t(i.expected_revision);d["desired_loadout"]=loadout;
 dispatch(peer,String(i.instance_id.c_str()),String(i.command_id.c_str()),i.sequence,bytes,d);
}
Dictionary WeaponNetworkBridge::send_intent(wpn::protocol::PredictionIntentKind kind,const Dictionary &request) {
 Dictionary result;result["sent"]=false;
 if(role!=ROLE_CLIENT||!client_ready||!is_multiplayer_active()){result["reason"]="session_not_ready";return result;}
 String instance=request.get("instance_id",String());
 if(!wpn::validate_identifier(text(instance)).ok()||local_counter>=uint64_t(INT64_MAX)||(!client_sequences.count(instance)&&client_sequences.size()>=wpn::MAX_BOUND_INSTANCES_PER_PEER))return result;
 String id="c"+String::num_int64(int64_t(++local_counter));uint64_t sequence=++client_sequences[instance];
 wpn::ByteWriter writer(wpn::MAX_COMMAND_BYTES);wpn::Status status;const char *rpc=nullptr;
 if(kind==wpn::protocol::PredictionIntentKind::FIRE){
  wpn::protocol::FireIntent i;i.command_id=text(id);i.instance_id=text(instance);i.sequence=sequence;i.expected_revision=positive(request.get("expected_revision",0));
  i.claimed_origin=from_point(request.get("claimed_origin",Dictionary()));i.claimed_aim=from_point(request.get("claimed_aim",Dictionary()));i.spread_seed=0;
  status=wpn::protocol::encode_fire_intent(i,writer);rpc="_rpc_fire_intent";
 } else if(kind==wpn::protocol::PredictionIntentKind::BEGIN_RELOAD){
  wpn::protocol::BeginReloadIntent i;i.command_id=text(id);i.instance_id=text(instance);i.sequence=sequence;i.expected_revision=positive(request.get("expected_revision",0));
  i.reservation_id=text(request.get("reservation_id",String()));uint64_t rounds=positive(request.get("reserved_rounds",0));if(rounds>UINT32_MAX)return result;i.reserved_rounds=uint32_t(rounds);
  status=wpn::protocol::encode_begin_reload_intent(i,writer);rpc="_rpc_begin_reload_intent";
 } else if(kind==wpn::protocol::PredictionIntentKind::CANCEL_RELOAD){
  wpn::protocol::CancelReloadIntent i;i.command_id=text(id);i.instance_id=text(instance);i.sequence=sequence;i.expected_revision=positive(request.get("expected_revision",0));
  status=wpn::protocol::encode_cancel_reload_intent(i,writer);rpc="_rpc_cancel_reload_intent";
 } else {
  if(request.get("desired_loadout",Variant()).get_type()!=Variant::ARRAY)return result;
  Array values=request["desired_loadout"];if(size_t(values.size())>wpn::MAX_ATTACHMENT_SLOTS_PER_WEAPON)return result;
  wpn::protocol::ConfigureAttachmentsIntent i;i.command_id=text(id);i.instance_id=text(instance);i.sequence=sequence;i.expected_revision=positive(request.get("expected_revision",0));
  for(int n=0;n<values.size();++n){if(values[n].get_type()!=Variant::DICTIONARY)return result;Dictionary d=values[n];wpn::AttachmentLoadoutEntry e;
   e.slot_id=text(d.get("slot_id",String()));e.attachment_id=text(d.get("attachment_id",String()));uint64_t version=positive(d.get("attachment_version",0));if(version>UINT16_MAX)return result;e.attachment_version=uint16_t(version);i.desired_loadout.push_back(e);}
  status=wpn::protocol::encode_configure_attachments_intent(i,writer);rpc="_rpc_configure_attachments_intent";
 }
 if(!status.ok()||rpc_id(server_peer_id,rpc,pack(client_token,writer.bytes()))!=OK)return result;
 wpn::protocol::PresentationIntent intent;intent.command_id=text(id);intent.instance_id=text(instance);intent.kind=kind;intent.sequence=sequence;intent.sent_tick=tick;
 std::optional<wpn::protocol::PredictionOutcome> evicted;prediction->track(intent,evicted);
 if(evicted)emit_signal("presentation_expired",String(evicted->intent.command_id.c_str()),String(evicted->intent.instance_id.c_str()),int(evicted->intent.kind));
 emit_signal("presentation_predicted",id,instance,int(kind));result["sent"]=true;result["command_id"]=id;return result;
}
Dictionary WeaponNetworkBridge::request_fire_networked(const Dictionary &v){return send_intent(wpn::protocol::PredictionIntentKind::FIRE,v);}
Dictionary WeaponNetworkBridge::request_begin_reload_networked(const Dictionary &v){return send_intent(wpn::protocol::PredictionIntentKind::BEGIN_RELOAD,v);}
Dictionary WeaponNetworkBridge::request_cancel_reload_networked(const Dictionary &v){return send_intent(wpn::protocol::PredictionIntentKind::CANCEL_RELOAD,v);}
Dictionary WeaponNetworkBridge::request_configure_attachments_networked(const Dictionary &v){return send_intent(wpn::protocol::PredictionIntentKind::CONFIGURE_ATTACHMENTS,v);}
bool WeaponNetworkBridge::request_resync(const String &instance) {
 if(role!=ROLE_CLIENT||!client_ready||!replica||!is_multiplayer_active()||!wpn::validate_identifier(text(instance)).ok())return false;
 auto request=replica->make_resync_request(text(instance));wpn::ByteWriter writer(wpn::MAX_COMMAND_BYTES);
 return wpn::protocol::encode_resync_request(request,writer).ok()&&rpc_id(server_peer_id,"_rpc_resync_request",pack(client_token,writer.bytes()))==OK;
}
Dictionary WeaponNetworkBridge::confirmed_snapshot(const String &instance) const {
 Dictionary d;if(!client_ready||!replica)return d;const auto *s=replica->find(text(instance));if(!s)return d;
 d["instance_id"]=instance;d["revision"]=int64_t(s->revision);d["loaded_rounds"]=int(s->loaded_rounds);d["phase"]=s->phase==wpn::WeaponPhase::READY?"ready":"reloading";
 d["recoil_vertical_offset_nrad"]=s->recoil_vertical_offset_nrad;d["recoil_horizontal_offset_nrad"]=s->recoil_horizontal_offset_nrad;d["recoil_anchor_tick"]=int64_t(s->recoil_anchor_tick);return d;
}
bool WeaponNetworkBridge::is_instance_tombstoned(const String &instance) const {return client_ready&&replica&&replica->is_tombstoned(text(instance));}
void WeaponNetworkBridge::acknowledge(const std::set<std::string> &ids) {
 wpn::protocol::AcknowledgementBatch batch;
 for(const auto &id:ids){wpn::protocol::DeltaAcknowledgement a;a.instance_id=id;a.acknowledged_revision=replica->last_applied_revision(id);batch.acknowledgements.push_back(a);}
 if(batch.acknowledgements.empty())return;
 wpn::ByteWriter writer(wpn::MAX_DELTA_BYTES);if(wpn::protocol::encode_acknowledgement_batch(batch,writer).ok())rpc_id(server_peer_id,"_rpc_acknowledgement_batch",pack(client_token,writer.bytes()));
}
void WeaponNetworkBridge::_rpc_snapshot_batch(const PackedByteArray &wire) {
 std::vector<uint8_t> bytes;if(!unpack_server(wire,wpn::MAX_SNAPSHOT_BYTES,bytes))return;
 wpn::protocol::WeaponSnapshotBatch batch;wpn::ByteReader reader(bytes);if(!wpn::protocol::decode_snapshot_batch(reader,batch).ok()||batch.protocol_version!=wpn::PROTOCOL_VERSION)return;
 std::set<std::string> ids;for(const auto &id:replica->tracked_instance_ids())ids.insert(id);
 for(const auto &s:batch.snapshots)ids.insert(s.instance_id);for(const auto &s:batch.tombstones)ids.insert(s.instance_id);
 if(ids.size()>wpn::MAX_BOUND_INSTANCES_PER_PEER)return;
 auto candidate=*replica;if(!candidate.apply_snapshot_batch(batch).ok())return;*replica=std::move(candidate);
 ids.clear();
 for(const auto &s:batch.snapshots){ids.insert(s.instance_id);emit_signal("snapshot_applied",String(s.instance_id.c_str()),int64_t(s.revision));}
 for(const auto &s:batch.tombstones){ids.insert(s.instance_id);emit_signal("instance_tombstoned",String(s.instance_id.c_str()),int64_t(s.revision));}
 acknowledge(ids); // Initial snapshots, including revision zero, establish a baseline.
}
void WeaponNetworkBridge::_rpc_delta_batch(const PackedByteArray &wire) {
 std::vector<uint8_t> bytes;if(!unpack_server(wire,wpn::MAX_DELTA_BYTES,bytes))return;
 wpn::protocol::WeaponDeltaBatch batch;wpn::ByteReader reader(bytes);if(!wpn::protocol::decode_delta_batch(reader,batch).ok()||batch.protocol_version!=wpn::PROTOCOL_VERSION)return;
 std::set<std::string> ids;
 for(const auto &d:batch.deltas){std::string id=d.lifecycle==wpn::protocol::WeaponLifecycleState::TOMBSTONED&&d.tombstone?d.tombstone->instance_id:d.snapshot.instance_id;
  if(!replica->find(id)&&!replica->is_tombstoned(id)&&replica->tracked_instance_ids().size()>=wpn::MAX_BOUND_INSTANCES_PER_PEER)continue;
  auto status=replica->apply_delta(d);
  if(status.ok()){ids.insert(id);emit_signal(d.lifecycle==wpn::protocol::WeaponLifecycleState::TOMBSTONED?"instance_tombstoned":"delta_applied",String(id.c_str()),int64_t(d.successor_revision));}
  else if(replica->needs_resync(id)){for(const auto &v:prediction->diverge_instance(id))emit_signal("presentation_diverged",String(v.intent.command_id.c_str()),String(id.c_str()),int(v.intent.kind));emit_signal("resync_needed",String(id.c_str()));request_resync(String(id.c_str()));}}
 acknowledge(ids);
}
void WeaponNetworkBridge::apply_result(const PackedByteArray &wire,bool success_allowed) {
 std::vector<uint8_t> bytes;if(!unpack_server(wire,wpn::MAX_COMMAND_BYTES,bytes))return;
 wpn::protocol::CommandRejection result;wpn::ByteReader reader(bytes);if(!wpn::protocol::decode_command_rejection(reader,result).ok()||result.protocol_version!=wpn::PROTOCOL_VERSION)return;
 if(result.status.ok()&&!success_allowed)return;
 auto pending_intent=prediction->reject(result.command_id);if(!pending_intent)return;
 if(pending_intent->intent.instance_id!=result.instance_id){emit_signal("presentation_diverged",String(pending_intent->intent.command_id.c_str()),String(pending_intent->intent.instance_id.c_str()),int(pending_intent->intent.kind));return;}
 String id(result.command_id.c_str()),instance(result.instance_id.c_str());
 if(result.status.ok())emit_signal("presentation_confirmed",id,instance,int(pending_intent->intent.kind));
 else emit_signal("presentation_reverted",id,instance,int(pending_intent->intent.kind),status_dict(result.status),confirmed_snapshot(instance));
}
void WeaponNetworkBridge::_rpc_command_rejection(const PackedByteArray &v){apply_result(v,false);}
void WeaponNetworkBridge::_rpc_command_result(const PackedByteArray &v){apply_result(v,true);}


void WeaponNetworkBridge::_bind_methods() {
 BIND_ENUM_CONSTANT(ROLE_SERVER); BIND_ENUM_CONSTANT(ROLE_CLIENT);
 #define B0(n) ClassDB::bind_method(D_METHOD(#n),&WeaponNetworkBridge::n)
 #define B1(n,a) ClassDB::bind_method(D_METHOD(#n,a),&WeaponNetworkBridge::n)
 #define B2(n,a,b) ClassDB::bind_method(D_METHOD(#n,a,b),&WeaponNetworkBridge::n)
 #define B3(n,a,b,c) ClassDB::bind_method(D_METHOD(#n,a,b,c),&WeaponNetworkBridge::n)
 B1(set_role,"role");B0(get_role);B1(set_weapon_authority_path,"path");B0(get_weapon_authority_path);
 B1(set_server_peer_id,"peer_id");B0(get_server_peer_id);B1(set_tick_rate,"tick_rate");B0(get_tick_rate);
 B1(set_authority_scope,"scope");B0(get_authority_scope);B1(set_authority_epoch,"epoch");B0(get_authority_epoch);
 B1(set_authority_context_provider,"callback");B0(get_authority_context_provider);
 B1(set_reload_profile_provider,"callback");B0(get_reload_profile_provider);
 B1(set_command_admission_handler,"callback");B0(get_command_admission_handler);
 B1(set_client_catalog_fingerprint,"fingerprint");B0(get_client_catalog_fingerprint);
 B0(get_hardening_revision);B0(is_multiplayer_active);B0(is_session_ready);B0(connection_token);B1(peer_state,"peer");
 B2(begin_session,"peer","session");B1(end_session,"peer");B1(drop_peer,"peer");
 B3(authorize_instance,"peer","instance_id","role");B2(revoke_instance,"peer","instance_id");
 B1(push_state,"tick");B1(replicate_teardown,"instance_id");
 B1(command_still_current,"command_id");B2(complete_command,"command_id","accepted");
 B1(request_fire_networked,"intent");B1(request_begin_reload_networked,"intent");
 B1(request_cancel_reload_networked,"intent");B1(request_configure_attachments_networked,"intent");
 B1(request_resync,"instance_id");B0(send_compatibility_handshake);B1(confirmed_snapshot,"instance_id");B1(is_instance_tombstoned,"instance_id");
 B0(_rpc_request_offer);B2(_rpc_session_offer,"token","manifest");B1(_rpc_session_ready,"token");B1(_rpc_session_closed,"token");
 B1(_rpc_instance_revoked,"bytes");B1(_rpc_compatibility_handshake,"bytes");B1(_rpc_fire_intent,"bytes");
 B1(_rpc_begin_reload_intent,"bytes");B1(_rpc_cancel_reload_intent,"bytes");B1(_rpc_configure_attachments_intent,"bytes");
 B1(_rpc_acknowledgement_batch,"bytes");B1(_rpc_resync_request,"bytes");B1(_rpc_snapshot_batch,"bytes");B1(_rpc_delta_batch,"bytes");
 B1(_rpc_command_rejection,"bytes");B1(_rpc_command_result,"bytes");
 #undef B0
 #undef B1
 #undef B2
 #undef B3
 ADD_PROPERTY(PropertyInfo(Variant::INT,"role",PROPERTY_HINT_ENUM,"Server,Client"),"set_role","get_role");
 ADD_PROPERTY(PropertyInfo(Variant::NODE_PATH,"weapon_authority_path"),"set_weapon_authority_path","get_weapon_authority_path");
 ADD_PROPERTY(PropertyInfo(Variant::INT,"server_peer_id"),"set_server_peer_id","get_server_peer_id");
 ADD_PROPERTY(PropertyInfo(Variant::INT,"tick_rate"),"set_tick_rate","get_tick_rate");
 ADD_PROPERTY(PropertyInfo(Variant::STRING,"authority_scope"),"set_authority_scope","get_authority_scope");
 ADD_PROPERTY(PropertyInfo(Variant::INT,"authority_epoch"),"set_authority_epoch","get_authority_epoch");
 ADD_PROPERTY(PropertyInfo(Variant::CALLABLE,"authority_context_provider"),"set_authority_context_provider","get_authority_context_provider");
 ADD_PROPERTY(PropertyInfo(Variant::CALLABLE,"reload_profile_provider"),"set_reload_profile_provider","get_reload_profile_provider");
 ADD_SIGNAL(MethodInfo("session_ready"));ADD_SIGNAL(MethodInfo("instance_revoked",PropertyInfo(Variant::STRING,"instance_id")));
 ADD_SIGNAL(MethodInfo("command_rejected",PropertyInfo(Variant::INT,"peer"),PropertyInfo(Variant::STRING,"command_id"),PropertyInfo(Variant::STRING,"instance_id"),PropertyInfo(Variant::DICTIONARY,"status")));
 ADD_SIGNAL(MethodInfo("network_diagnostic",PropertyInfo(Variant::INT,"peer"),PropertyInfo(Variant::DICTIONARY,"status")));
 for(const char *name:{"presentation_predicted","presentation_confirmed","presentation_diverged","presentation_expired"})
  ADD_SIGNAL(MethodInfo(name,PropertyInfo(Variant::STRING,"command_id"),PropertyInfo(Variant::STRING,"instance_id"),PropertyInfo(Variant::INT,"kind")));
 ADD_SIGNAL(MethodInfo("presentation_reverted",PropertyInfo(Variant::STRING,"command_id"),PropertyInfo(Variant::STRING,"instance_id"),PropertyInfo(Variant::INT,"kind"),PropertyInfo(Variant::DICTIONARY,"status"),PropertyInfo(Variant::DICTIONARY,"confirmed_snapshot")));
 for(const char *name:{"snapshot_applied","delta_applied","instance_tombstoned"})
  ADD_SIGNAL(MethodInfo(name,PropertyInfo(Variant::STRING,"instance_id"),PropertyInfo(Variant::INT,"revision")));
 ADD_SIGNAL(MethodInfo("resync_needed",PropertyInfo(Variant::STRING,"instance_id")));
}
} // namespace godot
