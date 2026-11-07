"""Behavior drivers; no product implementation or live board access."""
import argparse, concurrent.futures, datetime, hashlib, http.server, json, subprocess, sys, tempfile, threading, traceback, platform
from driver_support import World,Binding,event,selftest,FixtureError,HERE
OUT=HERE/'driver-evidence';OUT.mkdir(exist_ok=True)
CASES=json.loads((HERE/'cases.json').read_text(encoding='utf-8'))
def run_case(case):
 tid=case['id'][4:];task,n=tid.rsplit('-',1);n=int(n);checks=[];notes=[];worlds=[];bindings=[]
 def ck(label,a,e):checks.append({'assertion':label,'actual':a,'expected':e,'pass':a==e})
 with tempfile.TemporaryDirectory(prefix='gugu-driver-'+tid+'-') as tmp:
  w=World(tmp);worlds.append(w);b=Binding(w);bindings.append(b)
  def reopen():
   nonlocal w,b
   w=World(tmp);worlds.append(w);b=Binding(w);bindings.append(b)
  def call(op,req=None):return b.invoke(op,req or {})
  def status(value,outcome):ck('observable operation result',value.get('outcome'),outcome)
  def completion(**extra):return {'completionId':'cmp-1','projectId':'fixture-guguboard','ticketId':'FIX-1','runId':'run-1','leaseGeneration':1,'checkoutSha':'a'*40,'tree':'b'*40,'developer':'dev-1','session':'session-dev','tests':[{'command':'fixture-check','exit':0,'passed':3,'failed':0}],'evidence':[{'uri':'fixture://evidence','digest':hashlib.sha256(b'evidence').hexdigest()}],**extra}
  try:
   if task=='SCH-01':
    w.seed(config={'enabled':True,'notBefore':w.now,'intervalSec':60,'maxConcurrent':1,'revision':1})
    if n==1:
     w.now-=1;r=call('EvaluateDue');ck('no event before boundary',len(w.load()['outbox']),0);ck('clock consulted',w.calls('Clock')>0,True);status(r,'NotDue')
    elif n==2:
     call('EvaluateDue');call('EvaluateDue');ck('one durable event after two invocations',len(w.load()['outbox']),1)
    else:
     before=w.load()['config'];r=call('ConfigureSchedule',{'notBefore':'2026-11-07T09:00:00','intervalSec':4});ck('invalid config preserves persisted state',w.load()['config'],before);status(r,'Validation')
   elif task=='SCH-02':
    if n==1:
     w.seed(config={'enabled':True,'paused':True,'notBefore':w.now-1,'revision':1});call('EvaluateDue');ck('paused config read through store',w.calls('Store','Read')>0,True);ck('paused schedule emits no event',len(w.load()['outbox']),0)
    elif n==2:
     w.seed(cursor=w.now-180,config={'enabled':True,'notBefore':w.now-180,'intervalSec':60,'revision':1});reopen();call('ReconcileSchedule');ck('one current evaluation after reopen',len(w.load()['outbox']),1);ck('cursor catches up',w.load()['cursor'],w.now)
    else:
     w.seed(config={'enabled':True,'notBefore':w.now,'revision':1});before=w.load();w.faults['Store.Commit']=1;r=call('EvaluateDue');ck('commit fault reached',w.hits('Store.Commit'),1);ck('failed atomic write preserves snapshot',w.load(),before);status(r,'Unavailable')
   elif task=='WH-01':
    w.seed(outbox=[{'eventId':'evt-1','status':'pending','attempt':0}])
    if n==1:
     call('DeliverPending',{'eventId':'evt-1'});ck('real HTTP received request',w.request_count,1);ck('durable delivery receipt',w.load()['outbox'][0]['status'],'delivered');ck('not work completion',len(w.load()['journal']),0)
    elif n==2:
     w.http_mode='timeout';call('DeliverPending',{'eventId':'evt-1'});ck('timeout peer contacted',w.request_count,1);ck('retry state persisted',w.load()['outbox'][0]['status'],'retry');ck('event preserved',w.load()['outbox'][0]['eventId'],'evt-1')
    else:
     before=w.load()['config'];r=call('ConfigureTarget',{'url':'http://untrusted.invalid','allowedOrigins':[w.url.rsplit('/',1)[0]]});ck('no rejected network contact',w.request_count,0);ck('config unchanged',w.load()['config'],before);status(r,'Validation')
   elif task=='WH-02':
    w.seed(outbox=[{'eventId':'evt-1','body':'immutable-payload','status':'retry','attempt':1,'nextAt':w.now+10}])
    if n==1:
     call('RetryDue');ck('no early retry',w.request_count,0);w.now+=10;call('RetryDue');ck('actual retry at boundary',w.request_count,1);ck('stable event ID',w.load()['outbox'][0]['eventId'],'evt-1');ck('stable body',w.load()['outbox'][0]['body'],'immutable-payload')
    elif n==2:
     d=w.load();d['outbox'][0].update(attempt=5,nextAt=w.now);w.save(d);call('RetryDue');ck('bounded retries',w.request_count,0);ck('durable dead letter',w.load()['outbox'][0]['status'],'manual')
    else:
     before=w.load()['outbox'][0];reopen();call('ReconcileDelivery');ck('retry count survives reopen',w.load()['outbox'][0]['attempt'],before['attempt']);ck('retry time survives reopen',w.load()['outbox'][0]['nextAt'],before['nextAt']);w.now+=10;call('RetryDue');ck('recovered retry delivered',w.request_count,1)
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
     barrier=threading.Barrier(2);started=[]
     def contender(owner):barrier.wait(timeout=5);started.append(owner);return b.invoke('RunNext',{'owner':owner})
     with concurrent.futures.ThreadPoolExecutor(2) as pool:list(pool.map(contender,['worker-a','worker-b']))
     ck('two contenders cross actual barrier',len(started),2);ck('separate command processes',len({x['pid'] for x in b.invocations}),2);ck('one valid lease',len(w.load()['leases']),1);ck('one real process start',len(w.load()['runs']),1)
    elif n==2:
     w.faults['Process.Start']=1;call('RunNext');ck('actual start fault reached',w.hits('Process.Start'),1);ck('compensating release called',w.calls('Board','Release'),1);ck('no leaked lease',len(w.load()['leases']),0)
    else:
     w.seed(tickets={});r=call('RunNext');ck('claim attempted against empty board',w.calls('Board','Claim')>0,True);ck('no process',len(w.load()['runs']),0);status(r,'Idle')
   elif task=='RUN-03':
    w.rpc('Process','Start',{'ticket':'FIX-1'});w.seed(leases={'FIX-1':{'generation':1,'owner':'worker','until':w.now+900}});w.trace.clear()
    if n==1:
     w.now+=300;call('RenewRun',{'ticketId':'FIX-1'});ck('renew reached board port',w.calls('Board','Renew'),1);ck('valid lease child remains alive',w.children[0].poll(),None)
    elif n==2:
     w.faults['Board.Renew']=1;w.now+=840;call('RenewRun',{'ticketId':'FIX-1'});ck('renew fault reached',w.hits('Board.Renew'),1);ck('actual child stopped before expiry',w.children[0].poll() is not None,True);ck('stop confirmation called',w.calls('Process','Stop')>0,True)
    else:
     old=w;pid=old.children[0].pid;reopen();r=call('ReconcileRun',{'ticketId':'FIX-1','processMarker':{'pid':pid,'state':'unknown'}});ck('old child observable after reconstruct',old.children[0].poll(),None);ck('durable run quarantine',w.load()['runs'][0].get('quarantined'),True);ck('no new process',len(w.load()['runs']),1);status(r,'Quarantined')
   elif task=='CMP-01':
    d=w.load();d['tickets']['FIX-1']['status']='In Progress';d['leases']['FIX-1']={'generation':1,'owner':'dev-1'};w.save(d)
    if n==1:
     call('SubmitCompletion',completion());d=w.load();ck('durable completion journal',len(d['journal']),1);ck('delivery awaits independent review',d['tickets']['FIX-1']['status'],'In Review');ck('lease released',len(d['leases']),0)
    else:
     before=w.load();payload=completion(tests=[],evidence=[]) if n==2 else completion(leaseGeneration=0);r=call('SubmitCompletion',payload);ck('invalid delivery preserves snapshot',w.load(),before);status(r,'Validation' if n==2 else 'Conflict')
   elif task=='CMP-02':
    payload=completion()
    if n==1:
     call('SubmitCompletion',payload);reopen();call('SubmitCompletion',payload);ck('one journal after replay through fresh process',len(w.load()['journal']),1);ck('durable confirmed stage',w.load()['journal'].get('cmp-1',{}).get('stage'),'Confirmed')
    elif n==2:
     w.seed(journal={'cmp-1':{'stage':'ReviewUpdated','payload':payload}},leases={'FIX-1':{'generation':1}});w.faults['Board.Release']=1;call('ReconcileCompletion',{'completionId':'cmp-1'});ck('release fault reached',w.hits('Board.Release'),1);reopen();call('ReconcileCompletion',{'completionId':'cmp-1'});ck('lease released after fresh process',len(w.load()['leases']),0);ck('journal confirms',w.load()['journal']['cmp-1']['stage'],'Confirmed')
    else:
     w.seed(journal={'cmp-1':{'stage':'Confirmed','payload':payload,'digest':hashlib.sha256(json.dumps(payload,sort_keys=True).encode()).hexdigest()}});before=w.load();r=call('SubmitCompletion',completion(evidence=[{'uri':'fixture://changed','digest':'different'}]));ck('conflicting replay preserves evidence',w.load(),before);status(r,'Conflict')
   elif task=='RUN-04':
    w.seed(journal={'cmp-1':{'stage':'Confirmed' if n!=3 else 'Unknown'}},runs=[{'ticket':'FIX-1','session':'old-session'}]);d=w.load();d['tickets']['FIX-1']['status']='In Review'
    if n==2:d['tickets'].pop('FIX-2')
    w.save(d);r=call('RunNext',{'previousCompletionId':'cmp-1'})
    if n==1:
     ck('independent next ticket actually runs',any(x.get('ticket')=='FIX-2' for x in w.load()['runs']),True);ck('new execution session',any(x.get('session')!='old-session' for x in w.load()['runs'][1:]),True);ck('first task still awaits verification',w.load()['tickets']['FIX-1']['status'],'In Review')
    else:ck('no extra process',len(w.load()['runs']),1);status(r,'Idle' if n==2 else 'ReconcileRequired')
   elif task=='GOV-01':
    d=w.load();d['tickets']['FIX-1']['status']='In Review';w.save(d)
    if n==1:
     for actor in [{'verifier':'dev-1','session':'new-session'},{'verifier':'qa-1','session':'session-dev'}]:
      w.ident.update(actor);r=call('SubmitVerification',{'ticketId':'FIX-1','developerSession':'session-dev','tree':'b'*40,'evidence':'fixture://qa'});status(r,'Unauthorized')
     ck('no self-verification record',len(w.load()['verifications']),0)
    elif n==2:
     call('SubmitVerification',{'ticketId':'FIX-1','developerSession':'session-dev','tree':'b'*40,'evidence':'fixture://qa'});ck('independent evidence persisted',len(w.load()['verifications']),1);ck('verification not completion',w.load()['tickets']['FIX-1']['status'],'In Review')
    else:
     w.ident.update(role='reviewer',session='session-review');before=w.ident.copy();call('SubmitReview',{'ticketId':'FIX-1','tree':'b'*40,'evidence':'fixture://review'});ck('review durable',len(w.load()['reviews']),1);ck('trusted role not elevated',w.ident,before)
   elif task=='GOV-02':
    d=w.load();d['tickets']['FIX-1']['status']='In Review';w.save(d)
    if n==1:
     for gate in [{'verified':False,'reviewed':True,'merged':True},{'verified':True,'reviewed':True,'merged':False}]:
      w.seed(gates=gate);before=w.load();r=call('ApproveCompletion',{'ticketId':'FIX-1'});ck('incomplete gates cannot mutate',w.load(),before);status(r,'GateRejected')
    elif n==2:
     w.seed(gates={'verified':True,'reviewed':True,'authorized':True,'merged':True,'candidateTree':'b'*40,'mergedTree':'b'*40});call('ApproveCompletion',{'ticketId':'FIX-1'});ck('fully accepted task done',w.load()['tickets']['FIX-1']['status'],'Done');ck('fully accepted task blue',w.load()['tickets']['FIX-1']['light'],'Blue');ck('approval history durable',len(w.load()['approvals']),1)
    else:
     for actor in [{'role':'dev-agent','noApprove':False},{'role':'admin','noApprove':True}]:
      w.ident.update(actor);before=w.load();r=call('ApproveCompletion',{'ticketId':'FIX-1'});ck('unauthorized identity cannot mutate',w.load(),before);status(r,'Unauthorized')
   elif task.startswith('UI-'):
    operation={'UI-01':'GetScheduleView','UI-02':'GetWebhookView','UI-03':'GetRunView'}[task]
    if task=='UI-01' and n==3:w.ident.update(role='viewer')
    if task=='UI-02':w.seed(keyRef='test-key-1',secret='DO_NOT_RENDER_TEST_SECRET',runnerOnline=n!=3)
    if task=='UI-03':
     if n==1:w.seed(runs=[{'processStatus':'Exited','completionStatus':'Unknown'}])
     elif n==2:operation='GetGateView';w.seed(gates={'merged':False})
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
      if n==1:ck('default disabled checkbox',o['enabled'],False);ck('default concurrency visible',o['maxConcurrent'],'1')
      elif n==2:ck('validation alert after actual submit',bool(o['error']),True);ck('persisted config preserved',w.load()['config'],before['config'])
      else:ck('viewer save disabled',o['saveDisabled'],True);ck('viewer cannot write config',w.load()['config'],before['config'])
     elif task=='UI-02':
      if n==1:ck('key reference displayed',o['key'],'test-key-1');ck('secret absent from DOM','DO_NOT_RENDER_TEST_SECRET' in o['body'],False)
      elif n==2:ck('actual test delivery transport invoked',w.request_count,1);ck('health outcome visible',bool(o['health']),True);ck('test never starts real job',len(w.load()['runs']),0)
      else:ck('offline visible',o['runner'],'Offline');ck('pause usable',o['pauseDisabled'],False)
     else:
      if n==1:ck('process exit visible',o['process'],'Exited');ck('completion unknown visible separately',o['completion'],'Unknown')
      elif n==2:ck('unmerged completion disabled',o['completeDisabled'],True);ck('disabled reason visible',bool(o['reason']),True)
      else:ck('empty explanation visible',bool(o['empty']),True);ck('no invented success',o['success'],'')
    finally:server.shutdown();server.server_close();thread.join()
   elif task=='INT-01':
    w.seed(config={'enabled':True,'notBefore':w.now,'revision':1});call('EvaluateDue');call('DeliverPending',{'eventId':'evt-1'});raw,headers=event(w);b.ingress(raw,headers);call('RunNext')
    if n==1:
     call('SubmitCompletion',completion());call('RunNext',{'previousCompletionId':'cmp-1'});d=w.load();ck('second independent process starts',any(x.get('ticket')=='FIX-2' for x in d['runs']),True);ck('first task waits independent verification',d['tickets']['FIX-1']['status'],'In Review');ck('dependent never started',sum(x.get('ticket')=='FIX-3' for x in d['runs']),0)
    elif n==2:
     b.ingress(raw,headers);w.faults['Board.Release']=1;call('SubmitCompletion',completion());reopen();call('ReconcileCompletion',{'completionId':'cmp-1'});ck('one process despite replay',sum(x.get('ticket')=='FIX-1' for x in w.load()['runs']),1);ck('release interruption reached',sum(x.hits('Board.Release') for x in worlds),1);ck('completion restored after restart',w.load()['journal'].get('cmp-1',{}).get('stage'),'Confirmed')
    else:
     call('SubmitCompletion',completion());w.ident.update(verifier='qa-1',session='session-qa');call('SubmitVerification',{'ticketId':'FIX-1','tree':'b'*40});w.ident.update(reviewer='review-1',session='session-review',role='reviewer');call('SubmitReview',{'ticketId':'FIX-1','tree':'b'*40});w.ident.update(role='admin',session='session-human');w.seed(gates={'verified':True,'reviewed':True,'authorized':True,'merged':True,'candidateTree':'b'*40,'mergedTree':'b'*40});call('ApproveCompletion',{'ticketId':'FIX-1'});call('RunNext');d=w.load();ck('independent accepted task blue',d['tickets']['FIX-1']['light'],'Blue');ck('only done task unblocks dependencies',d['tickets']['FIX-1']['status'],'Done');ck('all three independent gate commands sent',len({x['operation'] for x in b.invocations if x['operation'] in ('SubmitVerification','SubmitReview','ApproveCompletion')}),3)
   else:raise FixtureError('missing driver:'+task)
   if not checks:raise FixtureError('no behavioral assertions')
   mismatches=[x for x in checks if not x['pass']];armed={key:sum(x.hits(key) for x in worlds) for world in worlds for key in world.faults}
   return {'id':case['id'],'bdd':case['bdd'],'status':'BEHAVIOR_RED' if mismatches else 'PASS','layer':'test-only input ports + executable boundary drivers','checks':checks,'trace':[t for x in worlds for t in x.trace],'invocations':[i for x in bindings for i in x.invocations],'faultHitCounts':armed,'missingFaultPaths':[k for k,h in armed.items() if not h],'notes':notes,'snapshot':w.load()}
  except Exception as e:return {'id':case['id'],'bdd':case['bdd'],'status':'INVALID_RED','error':str(e),'traceback':traceback.format_exc(),'checks':checks}
  finally:
   for world in reversed(worlds):world.close()

def main():
 parser=argparse.ArgumentParser();parser.add_argument('--task',default='*');parser.add_argument('--remaining',action='store_true');args=parser.parse_args();controls=selftest()
 selected=[c for c in CASES if (args.task=='*' or c['id'].startswith('TDD-'+args.task+'-')) and not(args.remaining and c['id'].startswith('TDD-SCH-01-'))]
 if not selected:raise FixtureError('empty discovery')
 results=[]
 for c in selected:
  r=run_case(c);results.append(r);print(c['id']+': '+r['status'],flush=True)
  if r['status']=='INVALID_RED':print(r['error'],flush=True)
 report={'date':datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=8))).isoformat(),'fixtureControls':controls,'results':results,'red':sum(r['status']=='BEHAVIOR_RED' for r in results),'passed':sum(r['status']=='PASS' for r in results),'invalid':sum(r['status']=='INVALID_RED' for r in results),'productionChanged':False,'independentAcceptance':'NOT RUN','provenance':{'python':sys.version,'platform':platform.platform(),'files':{name:hashlib.sha256((HERE/name).read_bytes()).hexdigest() for name in ['run_drivers.py','driver_support.py','Bridge.ps1','Skeleton.ps1','ui-skeleton.html','browser-driver.cjs','PortProbe.ps1','cases.json']}},'qualification':'RED against test-only empty application skeleton. Unreached fault ports demonstrate missing orchestration, not exercised fault handling. Real browser drives test-only UI, not product UI.'}
 suffix='remaining' if args.remaining else args.task.replace('*','all');(OUT/f'{suffix}.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8');print(json.dumps({k:report[k] for k in ['red','passed','invalid']}));return 2 if report['invalid'] else (1 if report['red'] else 0)
if __name__=='__main__':sys.exit(main())
