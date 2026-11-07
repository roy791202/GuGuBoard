"""Deliberately small, test-only control targets. Never the application under test.
Positive scripts exercise an oracle; mutations change a single known defect.
No script receives expected assertions, scenario IDs, or case.json values.
"""
import json,hashlib
from driver_support import Binding
class ControlBinding(Binding):
 mode='safe-time'
 def invoke(self,operation,request=None,state=None):
  request=request or {};w=self.world;d=w.load();self.invocations.append({'operation':operation,'pid':'control-only','mode':self.mode,'request':request})
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
  if self.mode=='claim-wrong-owner' and operation=='RunNext':
   lease=w.rpc('Board','Claim',{'ticket':'FIX-1','owner':request.get('owner','worker')})
   if lease.get('claimed'):w.rpc('Process','Start',{'ticket':'FIX-1','owner':'wrong-owner','generation':lease['generation']})
   return {}
  if self.mode=='accept-all-signatures' and operation=='AcceptWakeup':
   d['inbox'].append({'eventId':'unauthenticated'});w.save(d);return {'httpStatus':202}
  if self.mode=='trust-client-verifier' and operation=='SubmitVerification':
   d['verifications'].append({'actor':request.get('developer','dev-1')});w.save(d);return {'outcome':'VerificationSaved'}
  if self.mode=='approve-any-tree' and operation=='ApproveCompletion':
   d['tickets']['FIX-1'].update(status='Done',light='Blue');w.save(d);return {'outcome':'Approved'}
  if self.mode.startswith('ui-'):
   if operation=='GetScheduleView':return {'enabled':False,'maxConcurrent':1,'saveEnabled':self.mode=='ui-viewer-can-save','disabledReason':'PERMISSION_DENIED'}
   if operation=='SaveScheduleView':return {'outcome':'Unauthorized'}
   if operation=='GetWebhookView':return {'keyRef':d['keyRef'],**({'hiddenSecret':d['secret']} if self.mode=='ui-leak-hidden' else {})}
   if operation=='GetRunnerView':return {'runnerStatus':'Offline','pauseEnabled':True}
   if operation=='PauseDelivery':
    if self.mode!='ui-pause-noop':d['config']['paused']=True;w.save(d)
    return {'outcome':'Paused'}
   if operation=='DeliverPending':return {'outcome':'Paused'}
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
  directory=root_out/'controls'/case['id']/mode;directory.mkdir(parents=True,exist_ok=True)
  run_case.__globals__['OUT']=directory
  try:return run_case(case,factory(mode))
  finally:run_case.__globals__['OUT']=root_out
 plan=[('SCH-01-2','time-safe','reject-all'),('RUN-01-1','event-ack-script','reject-all'),('SCH-01-1','time-safe','time-ignore-boundary'),('SCH-02-1','time-safe','time-ignore-boundary'),('SCH-01-3',None,'config-accept-invalid'),('RUN-02-1',None,'claim-wrong-owner'),('RUN-02-3',None,'start-without-claim'),('RUN-01-2',None,'accept-all-signatures'),('CMP-01-2',None,'fake-error-mutates'),('GOV-01-1',None,'trust-client-verifier'),('GOV-02-1',None,'approve-any-tree'),('GOV-02-3',None,'approve-any-tree'),('UI-01-3','ui-safe','ui-viewer-can-save'),('UI-02-1','ui-safe','ui-leak-hidden'),('UI-02-3','ui-safe','ui-pause-noop'),('UI-03-2','ui-safe','ui-wrong-reason')]
 for short,positive,mutation in plan:
  identifier='TDD-'+short
  if identifier not in by_id:continue
  case=by_id[identifier];good=control_run(case,positive) if positive else base[identifier]
  bad=control_run(case,mutation);good_fail={x['assertion'] for x in good['checks'] if not x['pass']};bad_fail={x['assertion'] for x in bad['checks'] if not x['pass']};specific=sorted(bad_fail-good_fail)
  rows.append({'case':identifier,'positiveControl':positive,'positiveStatus':good['status'],'mutation':mutation,'mutationStatus':bad['status'],'newlyFailedAssertions':specific,'killed':bad['status']!='INVALID_RED' and bool(specific) and (positive is None or good['status']=='PASS'),'positiveChecks':good['checks'] if positive else None,'mutantChecks':bad['checks'],'positiveEvidence':good if positive else None,'mutantEvidence':bad})
 return rows
