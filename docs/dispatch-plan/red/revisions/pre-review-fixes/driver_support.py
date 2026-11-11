"""Executable test infrastructure only. Not a replacement product implementation."""
import contextlib, copy, hashlib, hmac, http.server, json, os, pathlib, queue, socket, subprocess, sys, tempfile, threading, time, urllib.request, urllib.error
HERE=pathlib.Path(__file__).resolve().parent
PW=os.environ.get('GUGU_TEST_PWSH',r'C:\Users\g6812\.cache\codex-runtimes\codex-primary-runtime\dependencies\native\powershell\pwsh.exe')
def clone(x): return copy.deepcopy(x)
class FixtureError(RuntimeError): pass
class World:
 def __init__(self,path):
  self.path=pathlib.Path(path);self.path.mkdir(parents=True,exist_ok=True);self.lock=threading.RLock();self.trace=[];self.faults={};self.children=[];self.now=1794013200;self.ident={'developer':'dev-1','verifier':'qa-1','reviewer':'review-1','session':'session-qa','role':'admin'};self.http_mode='ok';self.http_status=202;self.request_count=0
  if not (self.path/'state.json').exists(): self.save({'outbox':[],'inbox':[],'journal':{},'tickets':{'FIX-1':{'status':'Todo','light':'Gray','dependsOn':[]},'FIX-2':{'status':'Todo','light':'Gray','dependsOn':[]},'FIX-3':{'status':'Todo','light':'Gray','dependsOn':['FIX-1']}},'leases':{},'runs':[],'config':{'enabled':False,'intervalSec':60,'maxConcurrent':1,'revision':1},'cursor':0,'verifications':[],'reviews':[],'approvals':[]})
  world=self
  class Peer(http.server.BaseHTTPRequestHandler):
   def do_POST(self):
    body=self.rfile.read(int(self.headers.get('Content-Length',0)));world.request_count+=1
    world.trace.append({'kind':'peer','bytes':len(body),'mode':world.http_mode})
    if world.http_mode=='disconnect': self.connection.close();return
    if world.http_mode=='timeout':time.sleep(.25)
    try:self.send_response(world.http_status);self.end_headers();self.wfile.write(b'accepted')
    except (BrokenPipeError,ConnectionResetError,ConnectionAbortedError): pass
   def log_message(self,*a):pass
  self.peer=http.server.ThreadingHTTPServer(('127.0.0.1',0),Peer);self.thread=threading.Thread(target=self.peer.serve_forever,daemon=True);self.thread.start();self.url=f'http://127.0.0.1:{self.peer.server_port}/events'
 def load(self):
  with self.lock:return json.loads((self.path/'state.json').read_text())
 def save(self,value):
  with self.lock:
   tmp=self.path/'state.tmp';tmp.write_text(json.dumps(value));os.replace(tmp,self.path/'state.json')
 def seed(self,**kw):
  d=self.load();d.update(kw);self.save(d)
 def rpc(self,port,method,args):
  args=args or {};key=port+'.'+method
  with self.lock:
   self.trace.append({'kind':'port','port':port,'method':method,'args':clone(args)})
   if self.faults.get(key,0):
    self.faults[key]-=1;self.trace.append({'kind':'fault','point':key});raise OSError('injected:'+key)
   d=self.load()
   if port=='Clock':return self.now
   if port=='Identity':return clone(self.ident)
   if port=='Store':
    if method=='Read':return d
    if method=='Commit':self.save(args['state']);return {'saved':True}
    raise FixtureError('unknown Store method')
   if port=='Http':
    req=urllib.request.Request(self.url,data=bytes(args.get('body','{}'),'utf-8'),method='POST')
    try:
     with urllib.request.urlopen(req,timeout=.05) as r:return {'status':r.status,'body':r.read().decode()}
    except urllib.error.HTTPError as e:return {'status':e.code}
   if port=='Board':
    if method=='Read':return d
    if method=='Claim':
     ticket=args.get('ticket','FIX-1')
     if ticket in d['leases']:return {'claimed':False}
     d['leases'][ticket]={'generation':1,'owner':args.get('owner','worker')};self.save(d);return {'claimed':True,'ticket':ticket,'generation':1,'until':self.now+900}
    if method=='Renew':return {'until':self.now+900}
    if method=='Release':d['leases'].pop(args.get('ticket','FIX-1'),None);self.save(d);return {'released':True}
    if method=='Update':d['tickets'][args['ticket']].update(args['changes']);self.save(d);return {'updated':True}
    raise FixtureError('unknown Board method')
   if port=='Process':
    if method=='Start':
     p=subprocess.Popen([sys.executable,'-u','-c','import time; time.sleep(120)'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL);self.children.append(p);d['runs'].append({'pid':p.pid,'ticket':args.get('ticket','FIX-1'),'session':args.get('session','session-'+str(p.pid))});self.save(d);return {'pid':p.pid,'marker':str(p.pid)}
    if method=='Stop':
     for p in self.children:
      if p.poll() is None:p.terminate();p.wait(timeout=3)
     return {'exited':True}
    if method=='Inspect':return {'alive':any(p.poll() is None for p in self.children)}
    raise FixtureError('unknown Process method')
   raise FixtureError('unknown output port:'+port)
 def calls(self,port,method=None):return sum(x.get('kind')=='port' and x.get('port')==port and (method is None or x.get('method')==method) for x in self.trace)
 def hits(self,key):return sum(x.get('kind')=='fault' and x.get('point')==key for x in self.trace)
 def close(self):
  for p in self.children:
   if p.poll() is None:p.terminate();p.wait(timeout=3)
  self.peer.shutdown();self.peer.server_close();self.thread.join(timeout=3)

class Binding:
 def __init__(self,world,skeleton=None):self.world=world;self.skeleton=skeleton or HERE/'Skeleton.ps1';self.invocations=[];self.lock=threading.Lock()
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
     try:answer={'value':self.world.rpc(msg['port'],msg['method'],msg['arguments'])}
     except FixtureError:raise
     except Exception as e:answer={'error':str(e)};faults+=1
     p.stdin.write(json.dumps(answer)+'\n');p.stdin.flush()
    else:response=msg;break
   p.stdin.close();p.wait(timeout=5);stderr=p.stderr.read()
   if p.returncode or response is None:raise FixtureError('bridge failed:'+stderr)
   if response['kind']=='exception' and not faults:raise FixtureError('unexpected target exception:'+response['message'])
   record={'operation':operation,'pid':p.pid,'response':response,'faultsReturned':faults}
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
