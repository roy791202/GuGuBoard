"""Executable test infrastructure only. Not a replacement product implementation."""
import contextlib, copy, hashlib, hmac, http.server, json, os, pathlib, queue, socket, subprocess, sys, tempfile, threading, time, urllib.request, urllib.error
import ctypes
HERE=pathlib.Path(__file__).resolve().parent
PW=os.environ.get('GUGU_TEST_PWSH',r'C:\Users\g6812\.cache\codex-runtimes\codex-primary-runtime\dependencies\native\powershell\pwsh.exe')
def clone(x): return copy.deepcopy(x)
class FixtureError(RuntimeError): pass
class FaultPlan(dict):
 def __init__(self):super().__init__();self.armed=[]
 def __setitem__(self,key,value):
  if value>0:self.armed.append({'point':key,'count':value})
  super().__setitem__(key,value)
class NoRedirect(urllib.request.HTTPRedirectHandler):
 def redirect_request(self,*args):return None

def process_identity(pid):
 kernel=ctypes.WinDLL('kernel32',use_last_error=True)
 kernel.OpenProcess.restype=ctypes.c_void_p
 kernel.CloseHandle.argtypes=[ctypes.c_void_p]
 kernel.GetProcessTimes.argtypes=[ctypes.c_void_p]+[ctypes.c_void_p]*4
 kernel.GetExitCodeProcess.argtypes=[ctypes.c_void_p,ctypes.c_void_p]
 handle=kernel.OpenProcess(0x1000,False,int(pid))
 if not handle:return None
 try:
  exit_code=ctypes.c_uint32()
  if not kernel.GetExitCodeProcess(handle,ctypes.byref(exit_code)) or exit_code.value!=259:return None
  times=[ctypes.c_uint64() for _ in range(4)]
  if not kernel.GetProcessTimes(handle,*[ctypes.byref(x) for x in times]):return None
  return times[0].value
 finally:kernel.CloseHandle(handle)

def stop_owned_tree(pid,created):
 if process_identity(pid)!=created:return False
 result=subprocess.run(['taskkill','/PID',str(pid),'/T','/F'],capture_output=True)
 return result.returncode==0

class World:
 def __init__(self,path):
  self.path=pathlib.Path(path);self.path.mkdir(parents=True,exist_ok=True);self.lock=threading.RLock();self.trace=[];self.faults=FaultPlan();self.children=[];self.now=1794013200;self.ident={'actor':'dev-1','developer':'dev-1','verifier':'qa-1','reviewer':'review-1','session':'session-dev','role':'dev-agent'};self.http_mode='ok';self.http_status=202;self.request_count=0
  self.http_requests=[];self.claim_barrier=None;self.process_registry={};self.allowed_origins=set();self.transport_scale=0.005
  if not (self.path/'state.json').exists(): self.save({'outbox':[],'inbox':[],'journal':{},'tickets':{'FIX-1':{'status':'Todo','light':'Gray','dependsOn':[]},'FIX-2':{'status':'Todo','light':'Gray','dependsOn':[]},'FIX-3':{'status':'Todo','light':'Gray','dependsOn':['FIX-1']}},'leases':{},'runs':[],'config':{'enabled':False,'intervalSec':60,'maxConcurrent':1,'revision':1},'cursor':0,'verifications':[],'reviews':[],'approvals':[]})
  fixture=json.loads((HERE/'review-fixtures.json').read_text())
  if 'runLedger' not in self.load():self.seed(runLedger=fixture['runLedger'],principals=fixture['principals'],pr=fixture['pr'],evidence=fixture['evidence'],roleGrants=fixture['principals'])
  world=self
  class Peer(http.server.BaseHTTPRequestHandler):
   def do_POST(self):
    body=self.rfile.read(int(self.headers.get('Content-Length',0)));world.request_count+=1
    captured={'bodyHex':body.hex(),'headers':dict(self.headers),'path':self.path,'mode':world.http_mode}
    world.http_requests.append(captured)
    world.trace.append({'kind':'peer','bytes':len(body),'mode':world.http_mode,'request':captured})
    if world.http_mode=='disconnect': self.connection.close();return
    if world.http_mode=='timeout':time.sleep(.25)
    try:
     self.send_response(world.http_status)
     if 300<=world.http_status<400:self.send_header('Location',world.url+'/redirect')
     self.end_headers();self.wfile.write(b'accepted')
    except (BrokenPipeError,ConnectionResetError,ConnectionAbortedError): pass
   def log_message(self,*a):pass
  self.peer=http.server.ThreadingHTTPServer(('127.0.0.1',0),Peer);self.thread=threading.Thread(target=self.peer.serve_forever,daemon=True);self.thread.start();self.url=f'http://127.0.0.1:{self.peer.server_port}/events';self.allowed_origins.add(self.url.rsplit('/',1)[0])
  if 'httpPolicy' not in self.load():self.seed(httpPolicy={'allowedOrigins':sorted(self.allowed_origins),'timeoutSec':10,'followRedirects':False})
 def load(self):
  with self.lock:return json.loads((self.path/'state.json').read_text())
 def save(self,value):
  with self.lock:
   tmp=self.path/'state.tmp';tmp.write_text(json.dumps(value));os.replace(tmp,self.path/'state.json')
 def seed(self,**kw):
  d=self.load();d.update(kw);self.save(d)
 def rpc(self,port,method,args):
  args=args or {};key=port+'.'+method
  if key=='Board.Claim' and self.claim_barrier:self.claim_barrier.wait(timeout=8)
  with self.lock:
   self.trace.append({'kind':'port','port':port,'method':method,'args':clone(args)})
   if self.faults.get(key,0):
    dict.__setitem__(self.faults,key,self.faults[key]-1);self.trace.append({'kind':'fault','point':key});raise OSError('injected:'+key)
   d=self.load()
   if port=='Clock':return self.now
   if port=='Identity':return clone(self.ident)
   if port=='Secrets':return {'test-only':{'value':'test-only-key','validFrom':self.now-3600,'validUntil':self.now+3600},'expired-key':{'value':'test-only-key','validFrom':self.now-7200,'validUntil':self.now-3600}}
   if port=='PullRequest':return clone(d['pr'])
   if port=='Workspace':
    workspace=(self.path/'workspace').resolve()
    if method=='Quarantine':
     requested=pathlib.Path(args['path']).resolve()
     if requested!=workspace:raise FixtureError('workspace outside isolated fixture')
     requested.mkdir(exist_ok=True);(requested/'QUARANTINED').write_text(args.get('reason','LeaseLost'))
     d.setdefault('quarantinedWorkspaces',{})[str(requested)]=True;self.save(d);return {'quarantined':True}
    return {'quarantined':(workspace/'QUARANTINED').exists()}
   if port=='Store':
    if method=='Read':return d
    if method=='Commit':self.save(args['state']);return {'saved':True}
    raise FixtureError('unknown Store method')
   if port=='Http':
    url=args.get('url',self.url);deadline=args.get('timeoutSec',10)
    if not url.startswith('http://127.0.0.1:'):raise FixtureError('test transport refuses non-fixture destination; request captured in trace')
    self.trace.append({'kind':'transport','url':url,'headers':clone(args.get('headers',{})),'body':args.get('body','{}'),'timeoutSec':deadline})
    req=urllib.request.Request(url,data=bytes(args.get('body','{}'),'utf-8'),headers=args.get('headers',{}),method='POST')
    try:
     with urllib.request.build_opener(NoRedirect).open(req,timeout=deadline*self.transport_scale) as r:return {'status':r.status,'body':r.read().decode()}
    except urllib.error.HTTPError as e:return {'status':e.code}
   if port=='Board':
    if method=='Read':return d
    if method=='Claim':
     ticket=args.get('ticket','FIX-1')
     item=d['tickets'].get(ticket)
     if not item or item['status'] not in ('Todo','In Progress') or item.get('paused') or item.get('light')=='Red' or item.get('notBefore',0)>self.now:return {'claimed':False}
     if any(d['tickets'].get(dep,{}).get('status') not in ('Done','Released') for dep in item.get('dependsOn',[])):return {'claimed':False}
     lease=d['leases'].get(ticket)
     if lease and lease.get('until',self.now+1)>self.now:return {'claimed':False}
     generation=d.get('generations',{}).get(ticket,0)+1;d.setdefault('generations',{})[ticket]=generation
     d['leases'][ticket]={'generation':generation,'owner':args.get('owner','worker'),'until':self.now+900};self.save(d);return {'claimed':True,'ticket':ticket,'generation':generation,'until':self.now+900}
    if method in ('Renew','Release'):
     ticket=args.get('ticket','FIX-1');lease=d['leases'].get(ticket)
     if not lease or args.get('owner')!=lease['owner'] or args.get('generation')!=lease['generation']:return {'error':'LeaseLost'}
     if method=='Renew':lease['until']=self.now+900;self.save(d);return {'until':lease['until'],'generation':lease['generation']}
     d['leases'].pop(ticket);self.save(d);return {'released':True}
    if method=='Update':d['tickets'][args['ticket']].update(args['changes']);self.save(d);return {'updated':True}
    raise FixtureError('unknown Board method')
   if port=='Process':
    if method=='Start':
     marker=self.path/('tree-'+str(len(d['runs']))+'.json')
     code="import subprocess,sys,time,json;from pathlib import Path;p=subprocess.Popen([sys.executable,'-c','import time;time.sleep(120)']);Path(sys.argv[1]).write_text(json.dumps({'child':p.pid}));time.sleep(120)"
     p=subprocess.Popen([sys.executable,'-u','-c',code,str(marker)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL);self.children.append(p)
     for _ in range(100):
      if marker.exists():break
      time.sleep(.01)
     if not marker.exists():raise FixtureError('grandchild fixture did not start')
     grandchild=json.loads(marker.read_text())['child'];created=process_identity(p.pid)
     run={'pid':p.pid,'created':created,'descendant':grandchild,'descendantCreated':process_identity(grandchild),'ticket':args.get('ticket','FIX-1'),'runId':args.get('runId','run-1'),'session':args.get('session','session-'+str(p.pid)),'workspace':str(self.path/'workspace')}
     self.process_registry[p.pid]=run;d['runs'].append(run);self.save(d);return clone(run)
    if method=='Stop':
     matching=[r for r in d['runs'] if r.get('runId')==args.get('runId','run-1') and r.get('ticket')==args.get('ticket','FIX-1')]
     for run in matching:stop_owned_tree(run['pid'],run['created'])
     return {'exited':all(process_identity(r['pid'])!=r['created'] and process_identity(r['descendant'])!=r['descendantCreated'] for r in matching)}
    if method=='Inspect':return {'alive':any(process_identity(r.get('pid',0))==r.get('created') for r in d['runs'] if r.get('created') is not None),'runs':clone(d['runs'])}
    raise FixtureError('unknown Process method')
   raise FixtureError('unknown output port:'+port)
 def calls(self,port,method=None):return sum(x.get('kind')=='port' and x.get('port')==port and (method is None or x.get('method')==method) for x in self.trace)
 def hits(self,key):return sum(x.get('kind')=='fault' and x.get('point')==key for x in self.trace)
 def close(self):
  for p in self.children:
   if p.poll() is None:
    run=self.process_registry.get(p.pid)
    if run:stop_owned_tree(p.pid,run['created'])
    else:p.terminate()
    p.wait(timeout=3)
  self.peer.shutdown();self.peer.server_close();self.thread.join(timeout=3)

class Binding:
 def __init__(self,world,skeleton=None):self.world=world;self.skeleton=skeleton or HERE/'Skeleton.ps1';self.principal=None;self.invocations=[];self.lock=threading.Lock()
 def invoke(self,operation,request=None,state=None):
  packet={'operation':operation,'request':request or {},'state':state or {'outcome':'NotImplemented'}}
  p=subprocess.Popen([PW,'-NoProfile','-File',str(HERE/'Bridge.ps1'),'-SkeletonPath',str(self.skeleton)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,encoding='utf-8')
  lines=queue.Queue()
  def drain():
   for line in p.stdout:lines.put(line)
   lines.put(None)
  reader=threading.Thread(target=drain,daemon=True);reader.start()
  p.stdin.write(json.dumps(packet)+'\n');p.stdin.flush();response=None;faults=0
  try:
   while True:
    try:line=lines.get(timeout=20)
    except queue.Empty:raise FixtureError('bridge timeout')
    if line is None:break
    try:msg=json.loads(line.lstrip('\ufeff'))
    except ValueError:raise FixtureError('invalid bridge protocol:'+line)
    if msg['kind']=='port':
     try:answer={'value':clone(self.principal) if msg['port']=='Identity' and self.principal else self.world.rpc(msg['port'],msg['method'],msg['arguments'])}
     except FixtureError:raise
     except Exception as e:answer={'error':str(e)};faults+=1
     p.stdin.write(json.dumps(answer)+'\n');p.stdin.flush()
    else:response=msg;break
   p.stdin.close();p.wait(timeout=5);stderr=p.stderr.read()
   if p.returncode or response is None:raise FixtureError('bridge failed:'+stderr)
   if response['kind']=='exception' and not faults:raise FixtureError('unexpected target exception:'+response['message'])
   record={'operation':operation,'request':clone(request or {}),'trustedPrincipal':clone(self.principal or self.world.ident),'pid':p.pid,'response':response,'faultsReturned':faults}
   with self.lock:self.invocations.append(record)
   return response.get('value',{'unhandledDependencyFailure':True})
  finally:
   if p.poll() is None:p.kill();p.wait()
   p.stdout.close();p.stderr.close();reader.join(timeout=1)
 def ingress(self,raw,headers):
  binding=self
  class Ingress(http.server.BaseHTTPRequestHandler):
   def do_POST(self):
    body=self.rfile.read(int(self.headers.get('Content-Length',0)))
    result=binding.invoke('AcceptWakeup',{'rawBodyHex':body.hex(),'headers':dict(self.headers)})
    # Transport only: absence of target status is observable 200, never a made-up rejection.
    self.send_response(result.get('httpStatus',200));self.end_headers();self.wfile.write(json.dumps(result).encode())
   def log_message(self,*a):pass
  server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Ingress);thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
  try:
   req=urllib.request.Request(f'http://127.0.0.1:{server.server_port}/runner/v1/events',data=raw,headers=headers,method='POST')
   try:
    with urllib.request.urlopen(req,timeout=25) as r:return r.status,json.loads(r.read())
   except urllib.error.HTTPError as e:return e.code,json.loads(e.read())
  finally:server.shutdown();server.server_close();thread.join()

def event(world,age=0,tamper=False):
 raw=json.dumps({'schemaVersion':1,'eventId':'evt-1','projectId':'fixture-guguboard','scheduleRevision':1,'occurredAt':'2026-11-07T09:00:00+08:00','eventType':'wakeup','targetRunnerId':'runner-1'},separators=(',',':')).encode()
 stamp=str(world.now-age);signature=hmac.new(b'test-only-key',(stamp+'.').encode()+raw,hashlib.sha256).hexdigest()
 return raw+(b' ' if tamper else b''),{'Content-Type':'application/json','X-Key-Id':'test-only','X-Timestamp':stamp,'X-Signature':signature}

def selftest():
 with tempfile.TemporaryDirectory(prefix='gugu-fixture-control-') as tmp:
  w=World(tmp)
  try:
   w.faults['Store.Commit']=1;before=w.load()
   try:w.rpc('Store','Commit',{'state':{'bad':True}});raise AssertionError('fault not raised')
   except OSError:pass
   assert w.load()==before and w.hits('Store.Commit')==1
   from concurrent.futures import ThreadPoolExecutor
   barrier=threading.Barrier(2)
   def claim(owner):barrier.wait(timeout=5);return w.rpc('Board','Claim',{'owner':owner})
   with ThreadPoolExecutor(2) as pool: values=list(pool.map(claim,['a','b']))
   assert sum(x['claimed'] for x in values)==1
   w.http_mode='timeout'
   try:w.rpc('Http','Send',{});raise AssertionError('timeout missing')
   except (TimeoutError,socket.timeout):pass
   w.http_mode='disconnect'
   try:w.rpc('Http','Send',{});raise AssertionError('disconnect missing')
   except (OSError,ConnectionError):pass
   w.rpc('Process','Start',{});assert w.rpc('Process','Inspect',{})['alive'];w.rpc('Process','Stop',{});assert not w.rpc('Process','Inspect',{})['alive']
   saved=w.load();reloaded=World(pathlib.Path(tmp))
   try:assert reloaded.load()==saved
   finally:reloaded.close()
   raw,head=event(w);assert hmac.compare_digest(head['X-Signature'],hmac.new(b'test-only-key',(head['X-Timestamp']+'.').encode()+raw,hashlib.sha256).hexdigest())
   probe=Binding(w,HERE/'PortProbe.ps1');value=probe.invoke('Probe',{'port':'Clock','method':'Now','arguments':{}});assert value['probeValue']==w.now
   w.faults['Store.Commit']=1;failure=probe.invoke('Probe',{'port':'Store','method':'Commit','arguments':{'state':{}}});assert failure.get('unhandledDependencyFailure') is True
   return {'rpcPortInvocation':'PASS','rpcInjectedFault':'PASS','storeFault':'PASS','claimBarrier':'PASS','httpTimeout':'PASS','httpDisconnect':'PASS','realChildLifecycle':'PASS','durableReopen':'PASS','signedBytes':'PASS'}
  finally:w.close()
