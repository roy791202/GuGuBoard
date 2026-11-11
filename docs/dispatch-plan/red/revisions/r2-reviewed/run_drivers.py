"""Behavior drivers; no product implementation or live board access."""
import argparse, concurrent.futures, datetime, hashlib, http.server, json, subprocess, sys, tempfile, threading, traceback, platform
from driver_support import World,Binding,event,selftest,FixtureError,HERE
from review_strengthening import seed_gate_evidence
OUT=HERE/'review-fixes-evidence';OUT.mkdir(exist_ok=True)
CASES=json.loads((HERE/'review-case-inventory.json').read_text(encoding='utf-8'))
def run_case(case,binding_type=Binding):
 tid=case['id'][4:];task,n=tid.rsplit('-',1);n=int(n);checks=[];notes=[];worlds=[];bindings=[]
 def ck(label,a,e):checks.append({'assertion':label,'actual':a,'expected':e,'pass':a==e})
 with tempfile.TemporaryDirectory(prefix='gugu-driver-'+tid+'-') as tmp:
  w=World(tmp);worlds.append(w);b=binding_type(w);bindings.append(b)
  initial_tickets=w.load()['tickets']
  def reopen():
   nonlocal w,b
   w=World(tmp);worlds.append(w);b=binding_type(w);bindings.append(b)
  def call(op,req=None):return b.invoke(op,req or {})
  def status(value,outcome):ck('observable operation result',value.get('outcome'),outcome)
  def completion(**extra):return {'completionId':'cmp-1','projectId':'fixture-guguboard','ticketId':'FIX-1','runId':'run-1','leaseGeneration':1,'checkoutSha':'a'*40,'tree':'b'*40,'developer':'dev-1','session':'session-dev','tests':[{'command':'fixture-check','exit':0,'passed':3,'failed':0}],'evidence':[{'uri':'fixture://evidence','digest':hashlib.sha256(b'evidence').hexdigest()}],**extra}
  if task.startswith('UI-'):w.ident.update(actor='human-1',role='admin',session='session-human')
  if task=='GOV-01':w.ident.update(actor='qa-1',role='verifier',session='session-qa')
  if task=='GOV-02':w.ident.update(actor='human-1',role='admin',session='session-human')
  try:
   if task=='SCH-01':
    w.seed(config={'enabled':True,'notBefore':w.now,'intervalSec':60,'maxConcurrent':1,'revision':1})
    if n==1:
     w.now-=1;r=call('EvaluateDue');ck('no event before boundary',len(w.load()['outbox']),0);ck('no premature process',len(w.load()['runs']),0)
    elif n==2:
     call('EvaluateDue');call('EvaluateDue');ck('one durable event after two invocations',len(w.load()['outbox']),1)
    else:
     before=w.load()['config'];r=call('ConfigureSchedule',{'notBefore':'2026-11-07T09:00:00','intervalSec':4});ck('invalid config preserves persisted state',w.load()['config'],before);status(r,'Validation')
   elif task=='SCH-02':
    if n==1:
     w.seed(config={'enabled':True,'paused':True,'notBefore':w.now-1,'revision':1});call('EvaluateDue');ck('paused schedule starts no process',len(w.load()['runs']),0);ck('paused schedule emits no event',len(w.load()['outbox']),0)
    elif n==2:
     w.seed(cursor=w.now-180,config={'enabled':True,'notBefore':w.now-180,'intervalSec':60,'revision':1});reopen();call('ReconcileSchedule');ck('one current evaluation after reopen',len(w.load()['outbox']),1);ck('cursor catches up',w.load()['cursor'],w.now)
    else:
     w.seed(config={'enabled':True,'notBefore':w.now,'revision':1});before=w.load();w.faults['Store.Commit']=1;r=call('EvaluateDue');ck('commit fault reached',w.hits('Store.Commit'),1);ck('failed atomic write preserves snapshot',w.load(),before);status(r,'Unavailable')
   elif task=='WH-01':
    wire,headers=event(w);w.seed(outbox=[{'eventId':'evt-1','body':wire.decode(),'headers':headers,'url':w.url,'status':'pending','attempt':0}])
    if n==1:
     call('DeliverPending',{'eventId':'evt-1'});ck('real HTTP received request',w.request_count,1);ck('durable delivery receipt',w.load()['outbox'][0]['status'],'delivered');ck('not work completion',len(w.load()['journal']),0)
    elif n==2:
     w.http_mode='timeout';call('DeliverPending',{'eventId':'evt-1'});ck('timeout peer contacted',w.request_count,1);ck('retry state persisted',w.load()['outbox'][0]['status'],'retry');ck('event preserved',w.load()['outbox'][0]['eventId'],'evt-1')
    else:
     before=w.load()['config'];r=call('ConfigureTarget',{'url':'http://127.0.0.1:1/events'});ck('no rejected network contact',w.request_count,0);ck('config unchanged',w.load()['config'],before);status(r,'Validation')
   elif task=='WH-02':
    wire,headers=event(w);retry_body=wire.decode();w.seed(outbox=[{'eventId':'evt-1','body':retry_body,'headers':headers,'url':w.url,'status':'retry','attempt':1,'nextAt':w.now+10}])
    if n==1:
     call('RetryDue');ck('no early retry',w.request_count,0);w.now+=10;call('RetryDue');ck('actual retry at boundary',w.request_count,1);ck('stable event ID',w.load()['outbox'][0]['eventId'],'evt-1');ck('stable body',w.load()['outbox'][0]['body'],retry_body)
    elif n==2:
     d=w.load();d['outbox'][0].update(attempt=5,nextAt=w.now);w.save(d);call('RetryDue');ck('bounded retries',w.request_count,0);ck('durable dead letter',w.load()['outbox'][0]['status'],'manual')
    else:
     d=w.load();d['outbox'][0].update(status='pending',attempt=0,nextAt=None);w.save(d);w.http_mode='timeout';call('DeliverPending',{'eventId':'evt-1'});ck('subject persisted retry before restart',w.load()['outbox'][0]['status'],'retry');before=w.load()['outbox'][0];w.http_mode='ok';reopen();call('ReconcileDelivery');ck('retry count survives reopen',w.load()['outbox'][0]['attempt'],before['attempt']);ck('retry time survives reopen',w.load()['outbox'][0]['nextAt'],before['nextAt']);w.now+=10;call('RetryDue');ck('recovered retry delivered',sum(world.request_count for world in worlds),2)
   elif task=='RUN-01':
    if n==1:
     raw,headers=event(w);a=b.ingress(raw,headers);z=b.ingress(raw,headers);ck('durable HTTP dedup',len(w.load()['inbox']),1);ck('first acceptance',a[0],202);ck('duplicate status',z[0],200)
    elif n==2:
     for label,age,tamper in [('tampered',0,True),('stale',301,False)]:
      raw,headers=event(w,age,tamper);r=b.ingress(raw,headers);ck(label+' signed bytes rejected',r[0],401)
     ck('no unauthorized process',len(w.load()['runs']),0);ck('no unauthorized inbox',len(w.load()['inbox']),0)
    else:
     w.seed(inbox=[{'eventId':'existing','body':'preserve'}]);before=w.load()['inbox'];w.faults['Store.Commit']=1;raw,headers=event(w);r=b.ingress(raw,headers);ck('durability fault reached',w.hits('Store.Commit'),1);ck('failed persistence no ack',r[0],503);ck('existing inbox preserved',w.load()['inbox'],before)
     w.faults.clear();w.seed(inbox=[{'eventId':f'old-{i}'} for i in range(1000)]);r=b.ingress(raw,headers);ck('full inbox backpressure',r[0],429);ck('bounded inbox',len(w.load()['inbox']),1000)
   elif task=='RUN-02':
    if n==1:
     barrier=threading.Barrier(2);started=[];w.claim_barrier=threading.Barrier(2)
     def contender(owner):
      worker=binding_type(w);worker.principal={'actor':owner,'role':'dev-agent','session':'session-'+owner};barrier.wait(timeout=5);started.append(owner);value=worker.invoke('RunNext',{});
      with b.lock:b.invocations.extend(worker.invocations)
      return value
     with concurrent.futures.ThreadPoolExecutor(2) as pool:list(pool.map(contender,['worker-a','worker-b']))
     w.claim_barrier=None
     ck('two contenders cross actual barrier',len(started),2);ck('separate command processes',len({x['pid'] for x in b.invocations}),2);ck('one valid lease',len(w.load()['leases']),1);ck('one real process start',len(w.load()['runs']),1)
    elif n==2:
     w.faults['Process.Start']=1;call('RunNext');ck('actual start fault reached',w.hits('Process.Start'),1);ck('compensating release called',w.calls('Board','Release'),1);ck('no leaked lease',len(w.load()['leases']),0)
    else:
     w.seed(tickets={});r=call('RunNext');ck('empty board creates no lease',len(w.load()['leases']),0);ck('no process',len(w.load()['runs']),0);status(r,'Idle')
   elif task=='RUN-03':
    w.rpc('Process','Start',{'ticket':'FIX-1'});w.seed(leases={'FIX-1':{'generation':1,'owner':'worker','until':w.now+900}});w.trace.clear()
    if n==1:
     w.now+=300;call('RenewRun',{'ticketId':'FIX-1'});ck('renew reached board port',w.calls('Board','Renew'),1);ck('valid lease child remains alive',w.children[0].poll(),None)
    elif n==2:
     w.faults['Board.Renew']=1;w.now+=840;call('RenewRun',{'ticketId':'FIX-1'});ck('renew fault reached',w.hits('Board.Renew'),1);ck('actual child stopped before expiry',w.children[0].poll() is not None,True);ck('stop confirmation called',w.calls('Process','Stop')>0,True)
    else:
     old=w;pid=old.children[0].pid;reopen();r=call('ReconcileRun',{'ticketId':'FIX-1','processMarker':{'pid':pid,'state':'unknown'}});ck('old process must stop before recovery completes',old.children[0].poll() is not None,True);ck('durable run quarantine',w.load()['runs'][0].get('quarantined'),True);ck('no new process',len(w.load()['runs']),1);status(r,'Quarantined')
   elif task=='CMP-01':
    d=w.load();d['tickets']['FIX-1']['status']='In Progress';d['leases']['FIX-1']={'generation':1,'owner':'dev-1'};w.save(d)
    if n==1:
     call('SubmitCompletion',completion());d=w.load();ck('durable completion journal',len(d['journal']),1);ck('delivery awaits independent review',d['tickets']['FIX-1']['status'],'In Review');ck('lease released',len(d['leases']),0)
    else:
     before=w.load();payload=completion(tests=[],evidence=[]) if n==2 else completion(leaseGeneration=0);r=call('SubmitCompletion',payload);ck('invalid delivery preserves snapshot',w.load(),before);status(r,'Validation' if n==2 else 'Conflict')
   elif task=='CMP-02':
    payload=completion()
    if n==1:
     from review_strengthening import response_loss
     first_result=response_loss(b,payload);reopen();call('SubmitCompletion',payload);ck('one journal after replay through fresh process',len(w.load()['journal']),1);ck('durable confirmed stage',w.load()['journal'].get('cmp-1',{}).get('stage'),'Confirmed')
    elif n==2:
     d=w.load();d['tickets']['FIX-1'].update(status='In Review',tdd='Green',history=[{'tree':'b'*40}]);w.save(d);w.seed(journal={'cmp-1':{'stage':'ReviewUpdated','payload':payload,'receipt':'receipt-cmp-1'}},leases={'FIX-1':{'generation':1,'owner':'dev-1','until':w.now+900}});w.faults['Board.Release']=1;call('ReconcileCompletion',{'completionId':'cmp-1'});ck('release fault reached',w.hits('Board.Release'),1);reopen();call('ReconcileCompletion',{'completionId':'cmp-1'});ck('lease released after fresh process',len(w.load()['leases']),0);ck('journal confirms',w.load()['journal']['cmp-1']['stage'],'Confirmed')
    else:
     w.seed(journal={'cmp-1':{'stage':'Confirmed','payload':payload,'digest':hashlib.sha256(json.dumps(payload,sort_keys=True).encode()).hexdigest()}});before=w.load();d=w.load();d['evidence']['fixture://changed']={'exists':True,'digest':hashlib.sha256(b'changed-valid-evidence').hexdigest()};w.save(d);before=w.load();r=call('SubmitCompletion',completion(evidence=[{'uri':'fixture://changed','digest':hashlib.sha256(b'changed-valid-evidence').hexdigest()}]));ck('conflicting replay preserves evidence',w.load(),before);status(r,'Conflict')
   elif task=='RUN-04':
    w.seed(journal={'cmp-1':{'stage':'Confirmed' if n!=3 else 'Unknown'}},runs=[{'ticket':'FIX-1','session':'old-session'}]);d=w.load();d['tickets']['FIX-1']['status']='In Review'
    if n==2:d['tickets'].pop('FIX-2')
    w.save(d);r=call('RunNext',{'previousCompletionId':'cmp-1'})
    if n==1:
     ck('independent next ticket actually runs',any(x.get('ticket')=='FIX-2' for x in w.load()['runs']),True);ck('new execution session',any(isinstance(x.get('session'),str) and bool(x['session']) and x['session']!='old-session' for x in w.load()['runs'][1:]),True);ck('first task still awaits verification',w.load()['tickets']['FIX-1']['status'],'In Review')
    else:ck('no extra process',len(w.load()['runs']),1);status(r,'Idle' if n==2 else 'ReconcileRequired')
   elif task=='GOV-01':
    d=w.load();d['tickets']['FIX-1']['status']='In Review';w.save(d)
    if n==1:
     for actor in [{'verifier':'dev-1','session':'new-session'},{'verifier':'qa-1','session':'session-dev'}]:
      w.ident.update(actor);w.ident['actor']=actor['verifier'];r=call('SubmitVerification',{'ticketId':'FIX-1','developerSession':'session-dev','tree':'b'*40,'evidence':'fixture://qa'});status(r,'Unauthorized')
     ck('no self-verification record',len(w.load()['verifications']),0)
    elif n==2:
     call('SubmitVerification',{'ticketId':'FIX-1','developerSession':'session-dev','tree':'b'*40,'evidence':'fixture://qa'});ck('independent evidence persisted',len(w.load()['verifications']),1);ck('verification not completion',w.load()['tickets']['FIX-1']['status'],'In Review')
    else:
     w.ident.update(actor='review-1',role='reviewer',session='session-review');before=w.ident.copy();call('SubmitReview',{'ticketId':'FIX-1','tree':'b'*40,'evidence':'fixture://review'});ck('review durable',len(w.load()['reviews']),1);ck('trusted role not elevated',w.ident,before)
   elif task=='GOV-02':
    d=w.load();d['tickets']['FIX-1']['status']='In Review';w.save(d)
    if n==1:
     for gate in [{'verified':False,'reviewed':True,'merged':True},{'verified':True,'reviewed':True,'merged':False}]:
      seed_gate_evidence(w,gate);before=w.load();r=call('ApproveCompletion',{'ticketId':'FIX-1'});ck('incomplete gates cannot mutate',w.load(),before);status(r,'GateRejected')
    elif n==2:
     seed_gate_evidence(w,{'verified':True,'reviewed':True,'authorized':True,'merged':True,'candidateTree':'b'*40,'mergedTree':'b'*40});call('ApproveCompletion',{'ticketId':'FIX-1'});ck('fully accepted task done',w.load()['tickets']['FIX-1']['status'],'Done');ck('fully accepted task blue',w.load()['tickets']['FIX-1']['light'],'Blue');ck('approval history durable',len(w.load()['approvals']),1)
    else:
     for actor in [{'role':'dev-agent','noApprove':False},{'role':'admin','noApprove':True}]:
      w.ident.update(actor);w.ident['actor']='dev-1' if actor['role']=='dev-agent' else 'human-1';before=w.load();r=call('ApproveCompletion',{'ticketId':'FIX-1'});ck('unauthorized identity cannot mutate',w.load(),before);status(r,'Unauthorized')
   elif task.startswith('UI-'):
    operation={'UI-01':'GetScheduleView','UI-02':('GetRunnerView' if n==3 else 'GetWebhookView'),'UI-03':'GetRunView'}[task]
    if task=='UI-01' and n==3:w.ident.update(role='viewer')
    if task=='UI-02':w.seed(keyRef='test-key-1',secret='DO_NOT_RENDER_TEST_SECRET',runnerOnline=n!=3)
    if task=='UI-03':
     if n==1:w.seed(runs=[{'processStatus':'Exited','completionStatus':'Unknown'}])
     elif n==2:operation='GetGateView';seed_gate_evidence(w,{'merged':False})
     else:w.seed(runs=[])
    before=w.load();binding=b
    class UI(http.server.BaseHTTPRequestHandler):
     def do_GET(self):
      body=(HERE/'ui-skeleton.html').read_bytes();self.send_response(200);self.send_header('Content-Type','text/html; charset=utf-8');self.end_headers();self.wfile.write(body)
     def do_POST(self):
      packet=json.loads(self.rfile.read(int(self.headers['Content-Length'])));value=binding.invoke(packet['operation'],packet.get('request',{}));self.send_response(200);self.end_headers();self.wfile.write(json.dumps(value).encode())
     def log_message(self,*a):pass
    server=http.server.ThreadingHTTPServer(('127.0.0.1',0),UI);thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    try:
     artifact=OUT/(case['id']+'.png');p=subprocess.run(['node',str(HERE/'browser-driver.cjs'),f'http://127.0.0.1:{server.server_port}/?operation={operation}',f'{task}-{n}',str(artifact)],capture_output=True,text=True,encoding="utf-8",errors="strict",timeout=50)
     if p.returncode:raise FixtureError('browser driver:'+p.stderr)
     browser=json.loads(p.stdout.lstrip('\ufeff'));o=browser['observed'];notes.append({'browser':browser['browserVersion'],'screenshot':str(artifact)})
     if browser['errors']:raise FixtureError('browser errors:'+str(browser['errors']))
     if task=='UI-01':
      if n==1:ck('default disabled checkbox',o['enabled'],False);ck('default concurrency visible',o['maxConcurrent'],'1');ck('fixed concurrency cannot be edited',browser['concurrencyReadOnly'],True)
      elif n==2:ck('validation identifies notBefore field',browser['errorField'],'notBefore');ck('validation message identifies field','notBefore' in o['error'],True);ck('persisted config preserved',w.load()['config'],before['config'])
      else:ck('viewer save disabled',o['saveDisabled'],True);ck('viewer permission reason',o['reason'],'PERMISSION_DENIED');ck('forged API save rejected',browser['forcedResponse'].get('outcome'),'Unauthorized');ck('viewer cannot write config',w.load()['config'],before['config']);ck('forged viewer API preserves all state',w.load(),before)
     elif task=='UI-02':
      if n==1:ck('key reference displayed',o['key'],'test-key-1');ck('secret absent from all DOM and wire responses','DO_NOT_RENDER_TEST_SECRET' in browser['fullHTML']+json.dumps(browser['responses']),False)
      elif n==2:ck('actual test delivery transport invoked',w.request_count,1);ck('health outcome visible',bool(o['health']),True);ck('test never starts real job',len(w.load()['runs']),0);ck('test creates no inbox or lease',(w.load()['inbox'],w.load()['leases']),(before['inbox'],before['leases']))
      else:ck('offline visible',o['runner'],'Offline');ck('pause usable',o['pauseDisabled'],False);ck('click durably pauses delivery',w.load()['config'].get('paused'),True);beforeRequests=w.request_count;binding.invoke('DeliverPending',{});ck('paused delivery sends nothing',w.request_count,beforeRequests)
     else:
      if n==1:ck('process exit visible',o['process'],'Exited');ck('completion unknown visible separately',o['completion'],'Unknown')
      elif n==2:ck('unmerged completion disabled',o['completeDisabled'],True);ck('exact unmerged gate reason',o['reason'],'PR_NOT_MERGED');ck('forged completion rejected',browser['forcedResponse'].get('outcome'),'GateRejected');ck('forged complete API preserves all state',w.load(),before)
      else:ck('empty explanation visible',bool(o['empty']),True);ck('no invented success',o['success'],'')
    finally:server.shutdown();server.server_close();thread.join()
   elif task=='INT-01':
    pass  # The review driver composes real preceding-stage outputs below.
   else:raise FixtureError('missing driver:'+task)
   from review_strengthening import strengthen
   strengthen(case,locals())
   if not checks:raise FixtureError('no behavioral assertions')
   mismatches=[x for x in checks if not x['pass']];armed={key:sum(x.hits(key) for x in worlds) for world in worlds for armed_record in world.faults.armed for key in [armed_record['point']]}
   return {'id':case['id'],'bdd':case['bdd'],'status':'BEHAVIOR_RED' if mismatches else 'PASS','layer':'test-only input ports + executable boundary drivers','checks':checks,'trace':[t for x in worlds for t in x.trace],'invocations':[i for x in bindings for i in x.invocations],'faultHitCounts':armed,'missingFaultPaths':[k for k,h in armed.items() if not h],'notes':notes,'snapshot':w.load(),'lineage':{'feature':case['feature'],'scenarioDigest':case['featureDigest'],'fixtureDigest':hashlib.sha256((HERE/'review-fixtures.json').read_bytes()).hexdigest()},'faultArmedHistory':[entry for world in worlds for entry in world.faults.armed],'failureHandlingQualified':all(h>0 for h in armed.values()) if armed else None}
  except Exception as e:return {'id':case['id'],'bdd':case['bdd'],'status':'INVALID_RED','error':str(e),'traceback':traceback.format_exc(),'checks':checks}
  finally:
   for world in reversed(worlds):world.close()

def main():
 parser=argparse.ArgumentParser();parser.add_argument('--task',default='*');parser.add_argument('--remaining',action='store_true');parser.add_argument('--mutations',action='store_true');args=parser.parse_args();controls=selftest()
 selected=[c for c in CASES if (args.task=='*' or c['id'].startswith('TDD-'+args.task+'-')) and not(args.remaining and c['id'].startswith('TDD-SCH-01-'))]
 if not selected:raise FixtureError('empty discovery')
 results=[]
 for c in selected:
  r=run_case(c);results.append(r);print(c['id']+': '+r['status'],flush=True)
  if r['status']=='INVALID_RED':print(r['error'],flush=True)
 mutation_results=[]
 if args.mutations:
  from mutation_controls import run_controls
  mutation_results=run_controls(selected,run_case,results)
 report={'mutationControls':mutation_results,'date':datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=8))).isoformat(),'fixtureControls':controls,'results':results,'red':sum(r['status']=='BEHAVIOR_RED' for r in results),'passed':sum(r['status']=='PASS' for r in results),'invalid':sum(r['status']=='INVALID_RED' for r in results),'productionChanged':False,'independentAcceptance':'NOT RUN','provenance':{'python':sys.version,'platform':platform.platform(),'files':{name:hashlib.sha256((HERE/name).read_bytes()).hexdigest() for name in ['run_drivers.py','driver_support.py','Bridge.ps1','Skeleton.ps1','ui-skeleton.html','browser-driver.cjs','PortProbe.ps1','cases.json','review_strengthening.py','mutation_controls.py','review-fixtures.json','review-case-inventory.json']}},'qualification':'RED against test-only empty application skeleton. Unreached fault ports demonstrate missing orchestration, not exercised fault handling. Real browser drives test-only UI, not product UI.'}
 suffix='remaining' if args.remaining else args.task.replace('*','all');(OUT/f'{suffix}.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8');print(json.dumps({k:report[k] for k in ['red','passed','invalid']}));return 2 if report['invalid'] or any(not x['killed'] for x in mutation_results) else (1 if report['red'] else 0)
if __name__=='__main__':sys.exit(main())
