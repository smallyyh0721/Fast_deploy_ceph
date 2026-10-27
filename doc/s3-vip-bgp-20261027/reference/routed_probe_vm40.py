"""Future bounded VM40 routed probe. Run only after BOTH BGP peers/FIB are verified."""
import http.client,json,pathlib,signal,socket,subprocess,time
assert socket.gethostname()=='nettest-40'
def run(args):
 p=subprocess.run(args,stdin=subprocess.DEVNULL,capture_output=True,text=True,timeout=5)
 assert p.returncode==0,(args,p.stderr,p.stdout)
 return p.stdout
route=['10.11.4.50/32','via','10.11.4.1','dev','enp1s0']
assert not run(['ip','-4','route','show','exact','10.11.4.50/32']).strip(),'An existing /32 must not be overwritten'
assert run(['sysctl','-n','net.ipv4.conf.all.accept_redirects']).strip()=='0'
key='net.ipv4.conf.enp1s0.accept_redirects';original=run(['sysctl','-n',key]).strip()
added=False;result={'requests':[],'started_unix':time.time(),'original_redirects':original,'run_id':globals().get('SPLIT_RUN_ID')}
def stop(*_):raise InterruptedError('Probe interrupted; restoring temporary VM40 settings')
signal.signal(signal.SIGTERM,stop);signal.signal(signal.SIGINT,stop)
try:
 run(['sysctl','-w',key+'=0'])
 run(['ip','route','add']+route);added=True
 result['route']=run(['ip','route','get','10.11.4.50']);assert 'via 10.11.4.1' in result['route']
 deadline=time.monotonic()+40
 for _ in range(64):
  assert time.monotonic()<deadline,'Bounded probe deadline exceeded'
  connection=http.client.HTTPConnection('10.11.4.50',80,timeout=2)
  try:
   connection.connect();source_ip,source_port=connection.sock.getsockname()
   assert source_ip=='10.11.4.40'
   connection.request('GET','/',headers={'Connection':'close'})
   r=connection.getresponse()
   item={'status':r.status,'s3_xml':b'ListAllMyBucketsResult' in r.read(4096),'source_port':source_port}
  finally:connection.close()
  result['requests'].append(item);assert item['status']==200 and item['s3_xml']
  time.sleep(.1)
finally:
 if added:run(['ip','route','delete']+route)
 run(['sysctl','-w',key+'='+original])
result['restored_route']=run(['ip','route','get','10.11.4.50'])
result['restored_redirects']=run(['sysctl','-n',key]).strip()
result['remaining_exact_route']=run(['ip','-4','route','show','exact','10.11.4.50/32']).strip()
assert result['restored_redirects']==original and not result['remaining_exact_route']
result['finished_unix']=time.time()
print(json.dumps(result))
