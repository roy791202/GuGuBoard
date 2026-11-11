"""Deliberately small, test-only control targets. Never the application under test.
Positive scripts exercise an oracle; mutations change a single known defect.
No script receives expected assertions, scenario IDs, or case.json values.
"""
import json,hashlib,hmac,threading,copy
from driver_support import Binding
CONTROL_PLAN=[('UI-02-2','ui-health-script','ui-test-creates-job'),('RUN-03-1','renew-script','renew-no-persist'),('CMP-02-1','completion-commit-script','completion-duplicate'),('UI-03-1','ui-safe','ui-exited-as-running'),('UI-02-3','ui-safe','ui-ignore-delivery-pause'),('SCH-01-2','time-safe','reject-all'),('RUN-01-1','event-ack-script','reject-all'),('SCH-01-1','time-safe','time-ignore-boundary'),('SCH-02-1','time-safe','time-ignore-boundary'),('SCH-01-3','config-boundary-script','config-accept-invalid'),('RUN-02-1','run-claim-script','claim-wrong-owner'),('RUN-02-3','run-claim-script','start-without-claim'),('RUN-01-2','signed-ack-script','accept-all-signatures'),('CMP-01-2','completion-invalid-script','fake-error-mutates'),('GOV-01-1','verifier-reject-script','trust-client-verifier'),('GOV-02-1','gates-reject-script','approve-any-tree'),('GOV-02-3','gates-reject-script','approve-any-tree'),('UI-01-3','ui-safe','ui-viewer-can-save'),('UI-02-1','ui-safe','ui-leak-hidden'),('UI-02-3','ui-safe','ui-pause-noop'),('UI-03-2','ui-safe','ui-wrong-reason')]

class ControlBinding(Binding):
 mode='safe-time'
 def invoke(self,operation,request=None,state=None):
  request=request or {};w=self.world;d=w.load();self.invocations.append({'operation':operation,'pid':'control-thread-'+str(threading.get_ident()),'trustedPrincipal':copy.deepcopy(self.principal or w.ident),'mode':self.mode,'request':request})
  if self.mode=='config-boundary-script' and operation=='ConfigureSchedule':
   start=request.get('notBefore');interval=request.get('intervalSec')
   if not isinstance(start,str) or not start.endswith(('+08:00','Z')) or not isinstance(interval,int) or not 5<=interval<=3600:return {'outcome':'Validation'}
   d['config'].update(request);w.save(d);return {}
  if self.mode=='signed-ack-script' and operation=='AcceptWakeup':
   raw=bytes.fromhex(request['rawBodyHex']);headers={k.lower():v for k,v in request['headers'].items()};key_id=headers.get('x-key-id');stamp=headers.get('x-timestamp','');keys=w.rpc('Secrets','Read',{})
   try:stamp_number=int(stamp)
   except ValueError:return {'httpStatus':401}
   key=keys.get(key_id)
   if not key or not key['validFrom']<=w.now<=key['validUntil'] or abs(w.now-stamp_number)>300 or not hmac.compare_digest(headers.get('x-signature',''),hmac.new(key['value'].encode(),(stamp+'.').encode()+raw,hashlib.sha256).hexdigest()):return {'httpStatus':401}
   message=json.loads(raw);digest=hashlib.sha256(raw).hexdigest();existing=next((x for x in d['inbox'] if x['eventId']==message['eventId']),None)
   if existing:return {'httpStatus':200 if existing['digest']==digest else 409}
   d['inbox'].append({**message,'digest':digest});w.save(d);return {'httpStatus':202}
  if self.mode=='completion-invalid-script' and operation=='SubmitCompletion':
   tests=request.get('tests',[]);evidence=request.get('evidence',[])
   if not tests or not evidence or not(request.get('prUrl') or request.get('noPrReason')) or any(t['exit']!=0 or t['failed']!=0 or t.get('status')=='Unknown' or t.get('passed',0)+t.get('failed',0)==0 for t in tests) or any(not d['evidence'].get(e['uri'],{}).get('exists') or d['evidence'][e['uri']]['digest']!=e['digest'] for e in evidence):return {'outcome':'Validation'}
   return {'outcome':'UnexpectedValidControlInput'}
  if self.mode=='verifier-reject-script' and operation=='SubmitVerification':
   actor=w.ident['actor'];ledger=d['runLedger']['run-1'];principal=d['principals'][actor]
   if actor==ledger['owner'] or w.ident['session']==ledger['developerSession'] or w.ident['session']!=principal['session']:return {'outcome':'Unauthorized'}
   return {'outcome':'UnexpectedValidControlInput'}
  if self.mode=='gates-reject-script' and operation=='ApproveCompletion':
   actor=w.ident['actor'];grant=d['roleGrants'][actor]
   if w.ident.get('noApprove') or w.ident['role']!='admin' or grant['role']!='admin' or d['principals'][actor]['session']!=w.ident['session']:return {'outcome':'Unauthorized'}
   if not d['verifications'] or not d['reviews'] or not d['pr']['merged'] or d['pr']['candidateTree']!=d['pr']['mergedTree']:return {'outcome':'GateRejected'}
   return {'outcome':'UnexpectedValidControlInput'}
  if self.mode in ('renew-script','renew-no-persist') and operation=='RenewRun':
   lease=d['leases'][request['ticketId']]
   if self.mode=='renew-script':w.rpc('Board','Renew',{'ticket':request['ticketId'],'owner':w.ident['actor'],'generation':lease['generation']})
   return {'outcome':'Renewed'}
  if self.mode in ('completion-commit-script','completion-duplicate') and operation=='SubmitCompletion':
   cid=request['completionId'];digest=hashlib.sha256(json.dumps(request,sort_keys=True).encode()).hexdigest()
   if cid in d['journal']:
    record=d['journal'][cid]
    if record['digest']!=digest:return {'outcome':'Conflict'}
    if self.mode=='completion-duplicate':d['tickets'][request['ticketId']]['history'].append({'duplicate':True});w.save(d)
    return {'receipt':record['receipt']}
   lease=d['leases'].get(request['ticketId']);ledger=d['runLedger'][request['runId']]
   if not lease or lease['until']<=w.now or lease['owner']!=w.ident['actor'] or lease['generation']!=request['leaseGeneration'] or ledger['owner']!=w.ident['actor']:return {'outcome':'Conflict'}
   receipt='fixture-receipt-'+cid;d['journal'][cid]={'stage':'Confirmed','payload':copy.deepcopy(request),'receipt':receipt,'digest':digest};d['tickets'][request['ticketId']].update(status='In Review',tdd='Green',history=[{'tree':request['tree']}]);w.rpc('Store','Commit',{'state':d});w.rpc('Board','Release',{'ticket':request['ticketId'],'owner':lease['owner'],'generation':lease['generation']});return {'receipt':receipt}
  if self.mode=='event-ack-script' and operation=='AcceptWakeup':
   event=json.loads(bytes.fromhex(request['rawBodyHex']));duplicate=any(x['eventId']==event['eventId'] for x in d['inbox'])
   if not duplicate:d['inbox'].append(event);w.save(d)
   return {'httpStatus':200 if duplicate else 202}
  if self.mode.startswith('time-') and operation=='EvaluateDue':
   eligible=d['config'].get('enabled') and not d['config'].get('paused') and w.now>=d['config'].get('notBefore',0)
   if self.mode=='time-ignore-boundary' or eligible:
    if not d['outbox']:d['outbox'].append({'eventId':'control-event','revision':d['config']['revision']})
    w.save(d)
   return {}
  if self.mode in ('config-accept-invalid','fake-error-mutates'):
   d['config']['notBefore']=request.get('notBefore','corrupted');d['tickets']['FIX-1']['status']='Done';w.save(d);return {'outcome':'Validation'}
  if self.mode=='start-without-claim' and operation=='RunNext':
   w.rpc('Process','Start',{'ticket':'FIX-2','owner':'wrong','generation':-1});return {'outcome':'Started'}
  if self.mode in ('run-claim-script','claim-wrong-owner') and operation=='RunNext':
   if not d['tickets']:return {'outcome':'Idle'}
   actor=(self.principal or w.ident)['actor'];owner='attacker' if self.mode=='claim-wrong-owner' else actor
   lease=w.rpc('Board','Claim',{'ticket':'FIX-1','owner':owner})
   if lease.get('claimed'):w.rpc('Process','Start',{'ticket':'FIX-1','runId':'control-'+actor,'owner':owner,'generation':lease['generation']})
   return {}
  if self.mode=='accept-all-signatures' and operation=='AcceptWakeup':
   d['inbox'].append({'eventId':'unauthenticated'});w.save(d);return {'httpStatus':202}
  if self.mode=='trust-client-verifier' and operation=='SubmitVerification':
   d['verifications'].append({'actor':request.get('developer','dev-1')});w.save(d);return {'outcome':'VerificationSaved'}
  if self.mode=='approve-any-tree' and operation=='ApproveCompletion':
   d['tickets']['FIX-1'].update(status='Done',light='Blue');w.save(d);return {'outcome':'Approved'}
  if self.mode.startswith('ui-'):
   if operation=='TestDelivery':
    from driver_support import event
    raw,headers=event(w);message=json.loads(raw);message['testEvent']=True;raw=json.dumps(message,separators=(',',':')).encode();headers['X-Signature']=hmac.new(b'test-only-key',(headers['X-Timestamp']+'.').encode()+raw,hashlib.sha256).hexdigest();reply=w.rpc('Http','Send',{'url':w.url,'body':raw.decode(),'headers':headers,'timeoutSec':10});return {'health':'OK' if reply['status']==200 else 'FAILED'}
   if operation=='AcceptWakeup':
    message=json.loads(bytes.fromhex(request['rawBodyHex']))
    if self.mode=='ui-test-creates-job':d['inbox'].append(message);w.save(d)
    return {'httpStatus':200,'health':'OK'}
   if operation=='GetScheduleView':return {'enabled':False,'maxConcurrent':1,'saveEnabled':self.mode=='ui-viewer-can-save','disabledReason':'PERMISSION_DENIED'}
   if operation=='SaveScheduleView':return {'outcome':'Unauthorized'}
   if operation=='GetWebhookView':return {'keyRef':d['keyRef'],**({'hiddenSecret':d['secret']} if self.mode=='ui-leak-hidden' else {})}
   if operation=='GetRunView':return {'processStatus':'Running' if self.mode=='ui-exited-as-running' else 'Exited','completionStatus':'Unknown'}
   if operation=='GetRunnerView':return {'runnerStatus':'Offline','pauseEnabled':True}
   if operation=='PauseDelivery':
    if self.mode!='ui-pause-noop':d['config']['paused']=True;w.save(d)
    return {'outcome':'Paused'}
   if operation=='DeliverPending':
    if d['config'].get('paused') and self.mode!='ui-ignore-delivery-pause':return {'outcome':'Paused'}
    row=d['outbox'][0];w.rpc('Http','Send',{'url':row['url'],'body':row['body'],'headers':row['headers'],'timeoutSec':10});return {'outcome':'Sent'}
   if operation=='GetGateView':return {'completeEnabled':False,'disabledReason':'SOME_TEXT' if self.mode=='ui-wrong-reason' else 'PR_NOT_MERGED'}
   if operation=='ApproveCompletion':return {'outcome':'GateRejected'}
  return {'outcome':'Unauthorized' if self.mode=='reject-all' else 'NotImplemented'}

def factory(mode):
 class Selected(ControlBinding):pass
 Selected.mode=mode
 return Selected

def run_controls(inventory,run_case,baseline):
 by_id={c['id']:c for c in inventory};base={r['id']:r for r in baseline};rows=[]
 root_out=run_case.__globals__['OUT']
 def control_run(case,mode):
  directory=root_out/'controls'/str(len(rows))/case['id']/mode;directory.mkdir(parents=True,exist_ok=True)
  run_case.__globals__['OUT']=directory
  try:return run_case(case,factory(mode))
  finally:run_case.__globals__['OUT']=root_out
 plan=CONTROL_PLAN
 for short,positive,mutation in plan:
  identifier='TDD-'+short
  if identifier not in by_id:continue
  case=by_id[identifier];good=control_run(case,positive) if positive else base[identifier]
  bad=control_run(case,mutation);good_fail={x['assertion'] for x in good['checks'] if not x['pass']};bad_fail={x['assertion'] for x in bad['checks'] if not x['pass']};specific=sorted(bad_fail-good_fail)
  rows.append({'case':identifier,'positiveControl':positive,'positiveStatus':good['status'],'mutation':mutation,'mutationStatus':bad['status'],'newlyFailedAssertions':specific,'killed':bad['status']!='INVALID_RED' and bool(specific) and (positive is None or good['status']=='PASS'),'positiveChecks':good['checks'] if positive else None,'mutantChecks':bad['checks'],'positiveEvidence':good if positive else None,'mutantEvidence':bad})
 return rows
