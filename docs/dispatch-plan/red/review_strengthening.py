"""Additional contract assertions requested by independent review; no product behavior."""
import copy,hashlib,hmac,http.client,json,threading,http.server,urllib.request,time
from pathlib import Path
from driver_support import process_identity,HERE

def seed_gate_evidence(world,options):
 """Arrange trusted server records, never client-provided gate booleans."""
 d=world.load();tree=options.get('candidateTree','b'*40)
 d['verifications']=[{'actor':'qa-1','session':'session-qa','runId':'run-1','tree':tree,'result':'PASS','evidence':'fixture://qa'}] if options.get('verified',True) else []
 d['reviews']=[{'actor':'review-1','session':'session-review','runId':'run-1','tree':tree,'result':'PASS','evidence':'fixture://review'}] if options.get('reviewed',True) else []
 d['pr']={'id':'fixture-pr','merged':options.get('merged',True),'candidateTree':tree,'mergedTree':options.get('mergedTree',tree)}
 d['roleGrants']['human-1']['role']='admin' if options.get('authorized',True) else 'viewer'
 d['principals']['human-1']['role']=d['roleGrants']['human-1']['role']
 d.pop('gates',None);world.save(d)

def response_loss(binding,payload):
 """Drop an actual HTTP response only after subject durably saves its completion."""
 w=binding.world;point='Completion.ResponseAfterCommit';w.faults.armed.append({'point':point,'count':1})
 class Handler(http.server.BaseHTTPRequestHandler):
  def do_POST(self):
   request=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
   existed=request['completionId'] in w.load()['journal']
   result=binding.invoke('SubmitCompletion',request)
   if not existed and request['completionId'] in w.load()['journal']:
    w.trace.append({'kind':'fault','point':point});self.connection.shutdown(2);self.connection.close();return
   self.send_response(200);self.end_headers();self.wfile.write(json.dumps(result).encode())
  def log_message(self,*a):pass
 server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler);t=threading.Thread(target=server.serve_forever,daemon=True);t.start()
 try:
  req=urllib.request.Request(f'http://127.0.0.1:{server.server_port}/completion',data=json.dumps(payload).encode(),method='POST')
  try:
   with urllib.request.urlopen(req,timeout=30) as r:return json.loads(r.read())
  except http.client.RemoteDisconnected:return {'transport':'ResponseLost'}
 finally:server.shutdown();server.server_close();t.join()

def strengthen(case,ctx):
 task,n=case['id'][4:].rsplit('-',1);n=int(n);w=ctx['bindings'][-1].world;ck=ctx['ck'];call=ctx['call'];status=ctx['status'];completion=ctx['completion'];notes=ctx['notes']
 def unchanged(before):ck('complete authoritative snapshot unchanged',w.load(),before)
 def reject(op,payload,error):
  before=w.load();r=call(op,payload);status(r,error);unchanged(before)
 def calls(port,method):return [t for world in ctx['worlds'] for t in world.trace if t.get('kind')=='port' and t.get('port')==port and t.get('method')==method]
 # Security invariants detect wrong implementations even when a no-op safely passes.
 d=w.load()

 if task not in ('GOV-02','INT-01'):
  ck('development cannot mark any task Done or Blue',all(t['status']!='Done' and t.get('light')!='Blue' for t in d['tickets'].values()),True)
 if task=='SCH-01' and n==3:
  valid={'notBefore':'2026-11-07T09:00:00+08:00','intervalSec':60}
  for field,value in [('notBefore','2026-11-07T09:00:00'),('notBefore',''),('intervalSec',4),('intervalSec',3601)]:
   reject('ConfigureSchedule',{**valid,field:value},'Validation')
  for value in (5,3600):
   result=call('ConfigureSchedule',{**valid,'intervalSec':value});ck('valid boundary stored '+str(value),w.load()['config'].get('intervalSec'),value)
 elif task=='SCH-02' and n==2:
  before=w.load();call('ReconcileSchedule');ck('second reconciliation never adds another missed batch',w.load()['outbox'],before['outbox'])
 elif task=='SCH-02' and n==3:
  attempts=calls('Store','Commit');payload=attempts[0]['args'].get('state',{}) if attempts else {}
  ck('fault occurs with new cursor and outbox in same transaction',payload.get('cursor')==w.now and len(payload.get('outbox',[]))==1,True)
  w.faults.clear();call('EvaluateDue');ck('retry after storage recovery creates one event',len(w.load()['outbox']),1)
 elif task=='WH-01':
  if n==1:
   ck('delivery preserves all tickets',w.load()['tickets'],ctx['initial_tickets'])
  elif n==2:
   entry=w.load()['outbox'][0];ck('timeout classified',entry.get('lastError'),'Timeout');ck('timeout increments attempt',entry.get('attempt'),1);ck('timeout persists next retry',entry.get('nextAt'),w.now+10)
  elif n==3:
   # Exact disallowed loopback origin, observable even though transport itself is sandboxed.
   ck('rejected target cannot invoke HTTP transport',len(calls('Http','Send')),0);before=w.load();r=call('ConfigureTarget',{'url':w.url.replace('127.0.0.1','localhost')});status(r,'Validation');unchanged(before);ck('second rejected origin also causes no HTTP',len(calls('Http','Send')),0)
   call('ConfigureTarget',{'url':w.url});ck('permitted origin has positive configuration path',w.load()['config'].get('webhookUrl'),w.url)
 elif task=='WH-02' and n in (1,3):
  captures=[capture for world in ctx['worlds'] for capture in world.http_requests if capture['mode']=='ok'];ck('peer captures one delivered body',len(captures),1)
  if captures:
   capture=captures[0];raw=bytes.fromhex(capture['bodyHex']);headers={k.lower():v for k,v in capture['headers'].items()};stamp=headers.get('x-timestamp','')
   ck('actual wire body preserved',raw.decode(),ctx['retry_body'])
   ck('outgoing bytes have verifiable signature',hmac.compare_digest(headers.get('x-signature',''),hmac.new(b'test-only-key',(stamp+'.').encode()+raw,hashlib.sha256).hexdigest()),True)
   ck('outgoing signing time current',stamp,str(w.now))
  transport=[t for world in ctx['worlds'] for t in world.trace if t['kind']=='transport'];ck('declared delivery timeout is ten seconds',transport[0]['timeoutSec'] if transport else None,10)
 elif task=='RUN-01' and n==2:
  from driver_support import event
  for age in (-301,-300,300,301):
   raw,headers=event(w,age=age);response=ctx['bindings'][-1].ingress(raw,headers);ck('signature time boundary '+str(age),response[0],(202 if age==-300 else 200) if abs(age)<=300 else 401)
  raw,headers=event(w);response=ctx['bindings'][-1].ingress(raw,headers);ck('valid signed positive control accepted',response[0] in (200,202),True)
  for name,value in [('X-Key-Id','unknown-key'),('X-Key-Id','expired-key'),('X-Signature','')]:
   malformed={**headers,name:value};response=ctx['bindings'][-1].ingress(raw,malformed);ck('invalid trusted key/header '+name+value,response[0],401)
 elif task=='RUN-01' and n==3:
  ck('full inbox contents not truncated',w.load()['inbox'],[{'eventId':f'old-{i}'} for i in range(1000)])
  ck('storage fault remains in immutable history',any(a['point']=='Store.Commit' for a in w.faults.armed),True)
 elif task=='RUN-02' and n==1:
  starts=calls('Process','Start');leases=w.load()['leases']
  ck('lease owner is a real authenticated contender',all(lease['owner'] in {inv.get('trustedPrincipal',{}).get('actor') for inv in ctx['bindings'][0].invocations} for lease in leases.values()),True)
  ck('one real process adapter start',len(starts),1)
  ck('started process owned by winning generation',all(t['args'].get('owner')==leases.get(t['args'].get('ticket'),{}).get('owner') and t['args'].get('generation')==leases.get(t['args'].get('ticket'),{}).get('generation') for t in starts),True)
 elif task=='RUN-02' and n==2:
  claims=calls('Board','Claim');starts=calls('Process','Start');releases=calls('Board','Release')
  ck('claim reached before start failure',len(claims)>0,True)
  ck('compensation matches start owner and generation',bool(starts and releases) and all(releases[0]['args'].get(k)==starts[0]['args'].get(k) for k in ('ticket','owner','generation')),True)
  ck('failed start is reported',bool(w.load().get('reports')),True)
 elif task=='RUN-03':
  record=w.load()['runs'][0]
  if n==1:
   ck('renew persists new authoritative expiry',w.load()['leases']['FIX-1']['until'],w.now+900)
   ck('renew preserves generation',w.load()['leases']['FIX-1']['generation'],1)
  elif n==2:
   ck('descendant confirmed exited',process_identity(record['descendant'])!=record['descendantCreated'],True)
   ck('workspace quarantined after lost lease',w.load().get('quarantinedWorkspaces',{}).get(record['workspace']),True);ck('lost lease writes physical quarantine marker',Path(record['workspace'],'QUARANTINED').is_file(),True)
   second=w.rpc('Process','Start',{'ticket':'FIX-2','runId':'run-stop-fails','owner':'dev-1','generation':1});d=w.load();d['leases']['FIX-2']={'owner':'dev-1','generation':1,'until':w.now+60};d['runLedger']['run-stop-fails']={**d['runLedger']['run-1'],'runId':'run-stop-fails','ticketId':'FIX-2','workspace':second['workspace']};w.save(d)
   w.faults['Board.Renew']=1;w.faults['Process.Stop']=1;call('RenewRun',{'runId':'run-stop-fails','ticketId':'FIX-2'});ck('failed Stop actually reached on another live tree',w.hits('Process.Stop'),1);ck('failed Stop leaves its parent alive',process_identity(second['pid']),second['created']);ck('failed Stop leaves descendant alive',process_identity(second['descendant']),second['descendantCreated']);ck('failed Stop quarantines live workspace',w.load().get('quarantinedWorkspaces',{}).get(second['workspace']),True);ck('failed Stop writes physical quarantine marker',Path(second['workspace'],'QUARANTINED').is_file(),True);before=len(w.load()['runs']);call('RunNext');ck('failed stop blocks all new jobs',len(w.load()['runs']),before)
  else:
   ck('recovery checks trusted process creation marker',bool(calls('Process','Inspect')),True)
   ck('old descendant must be gone before continuing',process_identity(record['descendant'])!=record['descendantCreated'],True)
   ck('recovery writes physical workspace quarantine',__import__('pathlib').Path(record['workspace'],'QUARANTINED').is_file(),True)
   if process_identity(record['pid'])!=record['created'] and process_identity(record['descendant'])!=record['descendantCreated']:
    before=len(w.load()['runs']);call('RunNext');new=w.load()['runs'][before:];ck('new execution allowed after confirmed stop',len(new),1);ck('new execution isolated from old workspace',bool(new) and all(r.get('workspace')!=record['workspace'] and r.get('session')!=record.get('session') for r in new),True)
    foreign=w.rpc('Process','Start',{'ticket':'FIX-2','runId':'reused-marker','owner':'dev-1','generation':1});d=w.load();d['runs'][-1]['created']-=1;d['runLedger']['reused-marker']={**d['runLedger']['run-1'],'runId':'reused-marker','ticketId':'FIX-2','workspace':foreign['workspace']};d['leases']['FIX-2']={'owner':'dev-1','generation':1,'until':w.now+900};w.save(d);call('ReconcileRun',{'runId':'reused-marker','ticketId':'FIX-2'})
    ck('PID-reused foreign process is not killed',process_identity(foreign['pid']),foreign['created']);ck('PID mismatch workspace quarantined',Path(foreign['workspace'],'QUARANTINED').is_file(),True);before=len(w.load()['runs']);call('RunNext');ck('unresolved PID mismatch blocks new work',len(w.load()['runs']),before)
 elif task=='CMP-01':
  if n==1:
   journal=w.load()['journal'].get('cmp-1',{});ck('completion stores exact payload',journal.get('payload'),completion());ck('journal confirmed',journal.get('stage'),'Confirmed')
   ticket=w.load()['tickets']['FIX-1'];ck('delivery TDD marked Green',ticket.get('tdd'),'Green');ck('delivery history appended',bool(ticket.get('history')),True)
  elif n==2:
   for changes in [{'tests':[]},{'evidence':[]},{'noPrReason':''},{'tests':[{'command':'x','exit':0,'passed':0,'failed':0,'status':'Unknown'}]},{'evidence':[{'uri':'fixture://evidence','digest':hashlib.sha256(b'valid-format-wrong-content').hexdigest()}]},{'tests':[{'command':'x','exit':1,'passed':0,'failed':1}]},{'tests':[{'command':'x','exit':0,'passed':0,'failed':1}]},{'evidence':[{'uri':'fixture://missing','digest':hashlib.sha256(b'x').hexdigest()}]}]:reject('SubmitCompletion',completion(**changes),'Validation')
  else:
   for key,value in [('ticketId','FIX-2'),('runId','other-run'),('projectId','other-project'),('developer','qa-1'),('session','untrusted-session'),('checkoutSha','c'*40),('tree','d'*40)]:reject('SubmitCompletion',completion(**{key:value}),'Conflict')
 elif task=='CMP-02':
  if n==1:
   payload=completion();r=ctx['first_result'];ck('actual response loss after durable commit',r.get('transport'),'ResponseLost');replay=call('SubmitCompletion',payload)
   ck('confirmed receipt is present',w.load()['journal'].get('cmp-1',{}).get('receipt') is not None,True);ck('replay returns original persisted receipt',replay.get('receipt'),w.load()['journal'].get('cmp-1',{}).get('receipt'))
   ck('one append-only completion history',len(w.load()['tickets']['FIX-1'].get('history',[])),1)
  elif n==2:
   ck('recovery never repeats review update',len(calls('Board','Update')),0);ck('one successful resumed release',sum(t['kind']=='port' and t.get('port')=='Board' and t.get('method')=='Release' for t in w.trace),1)
 elif task=='RUN-04':
  if n==1:
   ck('next job really called process adapter',len(calls('Process','Start')),1);new=w.load()['runs'][1:];ck('next job is physically alive',bool(new) and all(r.get('created') is not None and process_identity(r.get('pid',0))==r['created'] for r in new),True)
  if n==2:ck('no dependent lease',w.load()['leases'].get('FIX-3'),None);ck('dependent was never claimed',any(t['args'].get('ticket')=='FIX-3' for t in calls('Board','Claim')),False)
  if n==3:ck('unknown completion triggers durable reconciliation',w.load().get('reconciliationPending'),True);ck('unknown completion acquires no lease',len(w.load()['leases']),0)
 elif task=='GOV-01':
  if n==1:
   ledger=w.load()['runLedger']['run-1'];reject('SubmitVerification',{'ticketId':'FIX-1','developerSession':'forged-session','developer':'forged-id','tree':ledger['tree']},'Unauthorized')
  if n==2:
   entries=w.load()['verifications'];ck('verification bound to trusted run tree',bool(entries) and all(e.get('tree')==w.load()['runLedger']['run-1']['tree'] and e.get('session')=='session-qa' for e in entries),True)
  if n==3:
   ck('persistent authorization grants remain exact',w.load()['roleGrants'],json.loads((HERE/'review-fixtures.json').read_text())['principals'])
   reject('SubmitReview',{'ticketId':'FIX-1','tree':'c'*40,'evidence':'fixture://review'},'Conflict')
 elif task=='GOV-02':
  if n==1:
   for missing in ('verified','reviewed','authorized','merged'):
    seed_gate_evidence(w,{missing:False});w.ident.update(role='viewer' if missing=='authorized' else 'admin');reject('ApproveCompletion',{'ticketId':'FIX-1'},'Unauthorized' if missing=='authorized' else 'GateRejected')
   seed_gate_evidence(w,{'candidateTree':'b'*40,'mergedTree':'c'*40});w.ident.update(role='admin');reject('ApproveCompletion',{'ticketId':'FIX-1'},'GateRejected')
  elif n==2:
   ticket=w.load()['tickets']['FIX-1'];ck('approval records immutable history',bool(ticket.get('history')),True);ck('approval history uses matching merged tree',bool(ticket.get('history')) and ticket['history'][-1].get('tree')==w.load()['pr']['mergedTree'],True)
  else:
   seed_gate_evidence(w,{})
   for actor in [{'role':'dev-agent','noApprove':False},{'role':'admin','noApprove':True}]:w.ident.update(actor);w.ident['actor']='dev-1' if actor['role']=='dev-agent' else 'human-1';w.ident['session']=w.load()['principals'][w.ident['actor']]['session'];reject('ApproveCompletion',{'ticketId':'FIX-1'},'Unauthorized')
 elif task=='INT-01':
  run_integration(case,ctx)

def run_integration(case,ctx):
 """Use preceding subject output; never manufacture an event/run to advance a stage."""
 task,n=case['id'][4:].rsplit('-',1);n=int(n);ck=ctx['ck'];call=ctx['call'];w=ctx['bindings'][-1].world;notes=ctx['notes'];b=ctx['bindings'][-1]
 if n==3:
  d=w.load();d['tickets']['FIX-2']['status']='Done';w.save(d)
 w.seed(config={'enabled':True,'notBefore':w.now,'revision':1})
 call('EvaluateDue');events=w.load()['outbox'];ck('scheduler produces actual next-stage event',len(events),1)
 if len(events)!=1:notes.append({'blockedStage':'scheduler→delivery','reason':'subject produced no event; no synthetic replacement'});return
 actual=events[0];event_id=actual.get('eventId');call('DeliverPending',{'eventId':event_id})
 ck('sender actually emitted event bytes',len(w.http_requests),1)
 if not w.http_requests:notes.append({'blockedStage':'delivery→ingress','reason':'no captured outgoing request'});return
 wire=w.http_requests[-1];raw=bytes.fromhex(wire['bodyHex']);headers=wire['headers'];accepted=b.ingress(raw,headers);ck('ingress accepts actual upstream delivery',accepted[0] in (200,202),True)
 if accepted[0] not in (200,202):notes.append({'blockedStage':'ingress→runner','reason':'ingress refused upstream event'});return
 if n==2:ck('duplicate upstream delivery acknowledged',b.ingress(raw,headers)[0],200)
 ck('ingress preserved scheduler event identity',w.load()['inbox'][0].get('eventId') if w.load()['inbox'] else None,event_id)
 if not w.load()['inbox']:notes.append({'blockedStage':'inbox→runner','reason':'no durable accepted event'});return
 call('RunNext');runs=w.load()['runs'];ck('runner starts one first job',len(runs),1)
 if not runs:notes.append({'blockedStage':'runner→completion','reason':'no actual run identity'});return
 run=runs[0];ledger=w.load()['runLedger'].get(run.get('runId'),{})
 signal=Path(run.get('completionSignal',''))
 if not signal.resolve().is_relative_to(w.path.resolve()) or process_identity(run.get('pid',0))!=run.get('created'):notes.append({'blockedStage':'process→completion','reason':'missing trusted physical run marker'});ck('completion has controlled physical run',False,True);return
 signal.write_text('finish normally')
 for _ in range(200):
  if process_identity(run['pid'])!=run['created']:break
  time.sleep(.01)
 ck('AI fixture exited before completion',process_identity(run['pid'])!=run['created'],True)
 lease=w.load()['leases'].get(run.get('ticket'),{});ck('run has matching trusted ledger and lease',bool(ledger) and ledger.get('owner')==lease.get('owner') and ledger.get('leaseGeneration')==lease.get('generation'),True)
 payload=ctx['completion'](runId=run.get('runId'),ticketId=run.get('ticket'),checkoutSha=ledger.get('checkoutSha'),tree=ledger.get('tree'),leaseGeneration=lease.get('generation'),developer=ledger.get('owner'),session=ledger.get('developerSession'))
 if n==2:
  r=response_loss(b,payload);ck('real post-commit response loss',r.get('transport'),'ResponseLost');ctx['reopen']();w=ctx['bindings'][-1].world;call('ReconcileCompletion',{'completionId':payload['completionId']});ck('restart confirms same delivery',w.load()['journal'].get(payload['completionId'],{}).get('stage'),'Confirmed');ck('duplicate event never starts twice',len(w.load()['runs']),1);return
 call('SubmitCompletion',payload)
 if n==1:
  call('RunNext',{'previousCompletionId':payload['completionId']});ck('actual next independent job',any(r.get('ticket')=='FIX-2' for r in w.load()['runs']),True);ck('dependent blocked before approval',any(r.get('ticket')=='FIX-3' for r in w.load()['runs']),False);return
 call('RunNext');ck('dependent not claimable before independent gates',any(r.get('ticket')=='FIX-3' for r in w.load()['runs']),False)
 for actor,role,op in [('qa-1','verifier','SubmitVerification'),('review-1','reviewer','SubmitReview'),('human-1','admin','ApproveCompletion')]:
  w.ident.update(actor=actor,role=role,session=w.load()['principals'][actor]['session']);call(op,{'ticketId':run['ticket'],'runId':run['runId'],'tree':ledger.get('tree'),'evidence':'fixture://qa' if role=='verifier' else 'fixture://review'})
 ck('verified merged task is Done',w.load()['tickets'][run['ticket']]['status'],'Done');ck('independently accepted task Blue',w.load()['tickets'][run['ticket']]['light'],'Blue');call('RunNext')
 ck('dependent FIX-3 actually starts after approval',any(r.get('ticket')=='FIX-3' for r in w.load()['runs']),True)


def assert_execution_authority(ctx):
 """Observe immutable capability calls, not mutable/exited application projections."""
 starts=[t for world in ctx['worlds'] for t in world.trace if t.get('kind')=='port' and t.get('port')=='Process' and t.get('method')=='Start' and t.get('callerPrincipal') is not None]
 valid=[]
 for event in starts:
  args=event['args'];lease=event.get('leaseAtCall') or {};principal=event['callerPrincipal']
  valid.append(bool(lease) and args.get('owner')==lease.get('owner')==principal.get('actor') and args.get('generation')==lease.get('generation') and lease.get('until',0)>event['clockAtCall'])
 ctx['ck']('every subject start has authenticated owner and fenced generation',all(valid),True)
