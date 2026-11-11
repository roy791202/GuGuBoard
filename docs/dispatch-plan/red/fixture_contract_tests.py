"""Fixture contract controls, separate from application acceptance and RED counts."""
import tempfile,unittest,json,copy
from pathlib import Path
from driver_support import World,process_identity
from review_strengthening import response_loss
class FixtureContracts(unittest.TestCase):
 def setUp(self):self.temp=tempfile.TemporaryDirectory(prefix='gugu-review-controls-');self.worlds=[];self.w=self.world()
 def world(self):
  w=World(self.temp.name);self.worlds.append(w);return w
 def tearDown(self):
  for w in reversed(self.worlds):w.close()
  self.temp.cleanup()
 def test_armed_fault_survives_cancel_and_is_counted_only_if_reached(self):
  self.w.faults['Store.Commit']=1;self.w.faults.clear();self.assertEqual(self.w.hits('Store.Commit'),0);self.assertEqual(len(self.w.faults.armed),1)
  before=self.w.load();self.w.faults['Store.Commit']=1
  with self.assertRaises(OSError):self.w.rpc('Store','Commit',{'state':{}})
  self.assertEqual(self.w.load(),before);self.assertEqual(self.w.hits('Store.Commit'),1);self.assertEqual(len(self.w.faults.armed),2)
 def test_board_rejects_missing_blocked_and_future_tickets(self):
  for ticket in ('missing','FIX-3'):self.assertFalse(self.w.rpc('Board','Claim',{'ticket':ticket,'owner':'a'})['claimed'])
  d=self.w.load();d['tickets']['FIX-2']['notBefore']=self.w.now+1;self.w.save(d);self.assertFalse(self.w.rpc('Board','Claim',{'ticket':'FIX-2','owner':'a'})['claimed']);self.assertEqual(self.w.load()['leases'],{})
 def test_generation_owner_fencing_and_persisted_renewal(self):
  a=self.w.rpc('Board','Claim',{'ticket':'FIX-1','owner':'a'});self.w.now+=300
  self.assertEqual(self.w.rpc('Board','Renew',{'ticket':'FIX-1','owner':'wrong','generation':a['generation']})['error'],'LeaseLost')
  renewed=self.w.rpc('Board','Renew',{'ticket':'FIX-1','owner':'a','generation':a['generation']});self.assertGreater(renewed['until'],a['until']);self.assertEqual(self.world().load()['leases']['FIX-1']['until'],renewed['until'])
  self.w.now=renewed['until']+1;b=self.w.rpc('Board','Claim',{'ticket':'FIX-1','owner':'b'});self.assertGreater(b['generation'],a['generation']);self.assertEqual(self.w.rpc('Board','Release',{'ticket':'FIX-1','owner':'a','generation':a['generation']})['error'],'LeaseLost');self.assertEqual(self.w.load()['leases']['FIX-1']['owner'],'b')
 def test_expired_lease_cannot_renew_or_release_before_reclaim(self):
  a=self.w.rpc('Board','Claim',{'ticket':'FIX-1','owner':'a'});self.w.now=a['until']
  for method in ('Renew','Release'):self.assertEqual(self.w.rpc('Board',method,{'ticket':'FIX-1','owner':'a','generation':a['generation']})['error'],'LeaseLost')
 def test_stop_is_targeted_and_survives_world_reconstruction(self):
  a=self.w.rpc('Process','Start',{'ticket':'FIX-1','runId':'run-a'});b=self.w.rpc('Process','Start',{'ticket':'FIX-2','runId':'run-b'});reopened=self.world()
  self.assertTrue(reopened.rpc('Process','Inspect',{})['alive']);result=reopened.rpc('Process','Stop',{'ticket':'FIX-1','runId':'run-a'});self.assertTrue(result['exited']);self.assertIsNone(process_identity(a['descendant']));self.assertEqual(process_identity(b['pid']),b['created']);self.assertEqual(process_identity(b['descendant']),b['descendantCreated'])
 def test_start_authority_observer_ignores_exited_projection_lie(self):
  from review_strengthening import assert_execution_authority
  principal={'actor':'dev-1','role':'dev-agent','session':'session-dev'}
  with self.w.as_principal(principal):
   lease=self.w.rpc('Board','Claim',{'ticket':'FIX-1','owner':'dev-1'});self.w.rpc('Process','Start',{'ticket':'FIX-1','runId':'observer-good','owner':'dev-1','generation':lease['generation']})
  observed=[];ctx={'worlds':[self.w],'ck':lambda name,a,e:observed.append(a==e)};assert_execution_authority(ctx);self.assertTrue(observed[-1])
  with self.w.as_principal(principal):self.w.rpc('Process','Start',{'ticket':'FIX-1','runId':'observer-bad','owner':'intruder','generation':999})
  d=self.w.load();d['runs'][-1]['processStatus']='Exited';self.w.save(d);assert_execution_authority(ctx);self.assertFalse(observed[-1])
 def test_identity_mismatch_cannot_kill_reused_pid(self):
  a=self.w.rpc('Process','Start',{'ticket':'FIX-1','runId':'old-marker'});d=self.w.load();d['runs'][0]['created']-=1;self.w.save(d)
  self.assertTrue(self.w.rpc('Process','Inspect',{})['identityMismatch']);self.assertFalse(self.w.rpc('Process','Stop',{'ticket':'FIX-1','runId':'old-marker'})['exited']);self.assertEqual(process_identity(a['pid']),a['created'])
 def test_fixture_tree_can_exit_normally_before_completion(self):
  import time
  a=self.w.rpc('Process','Start',{'ticket':'FIX-1','runId':'normal-exit'});Path(a['completionSignal']).write_text('complete')
  self.assertEqual(self.w.children[0].wait(timeout=3),0);self.assertIsNone(process_identity(a['descendant']))
 def test_http_preserves_url_headers_body_deadline_and_disables_redirect(self):
  self.w.http_status=302;result=self.w.rpc('Http','Send',{'url':self.w.url,'headers':{'X-Test':'wire-proof'},'body':'known-utf8-payload','timeoutSec':10})
  self.assertEqual(result['status'],302);self.assertEqual(self.w.request_count,1);wire=self.w.http_requests[0];self.assertEqual(bytes.fromhex(wire['bodyHex']),b'known-utf8-payload');self.assertEqual(wire['headers']['X-Test'],'wire-proof');self.assertEqual([t for t in self.w.trace if t['kind']=='transport'][0]['timeoutSec'],10)
 def test_response_loss_is_actual_http_disconnect_after_new_commit(self):
  world=self.w
  class OpaqueCommitControl:
   def __init__(self):self.world=world
   def invoke(self,op,request):
    d=world.load();d['journal'][request['completionId']]={'opaque':copy.deepcopy(request)};world.rpc('Store','Commit',{'state':d});return {'saved':True}
  result=response_loss(OpaqueCommitControl(),{'completionId':'fixture-cmp','opaque':'x'});self.assertEqual(result,{'transport':'ResponseLost'});self.assertEqual(world.hits('Completion.ResponseAfterCommit'),1)
 def test_composition_driver_stops_after_rejected_ingress(self):
  from review_strengthening import run_integration
  from driver_support import event
  world=self.w;raw,headers=event(world);operations=[];observations=[]
  class RefusedIngressControl:
   def __init__(self):self.world=world
   def ingress(self,raw,headers):return 401,{}
  binding=RefusedIngressControl()
  def arrange_stage(op,request=None):
   operations.append(op)
   if op=='EvaluateDue':world.seed(outbox=[{'eventId':'evt-1'}])
   if op=='DeliverPending':world.http_requests.append({'bodyHex':raw.hex(),'headers':headers})
   return {}
  ctx={'ck':lambda name,a,e:observations.append((name,a==e)),'call':arrange_stage,'bindings':[binding],'notes':[]}
  run_integration({'id':'TDD-INT-01-1'},ctx)
  self.assertNotIn('RunNext',operations);self.assertEqual(ctx['notes'][0]['blockedStage'],'ingress→runner')
 def test_workspace_quarantine_is_real_and_confined(self):
  workspace=self.w.path/'workspace';self.w.seed(runs=[{'workspace':str(workspace)}]);self.w.rpc('Workspace','Quarantine',{'path':str(workspace),'reason':'LeaseLost'});self.assertTrue((workspace/'QUARANTINED').is_file());self.assertTrue((workspace/'QUARANTINED').exists())
if __name__=='__main__':unittest.main(verbosity=2)
