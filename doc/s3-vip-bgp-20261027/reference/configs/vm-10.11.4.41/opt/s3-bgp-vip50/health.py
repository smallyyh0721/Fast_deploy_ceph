"""Health owner for BGP VIP50 using the existing cephadm ingress; no config writes to Ceph."""
import argparse,base64,csv,io,json,os,pathlib,re,signal,socket,subprocess,time,urllib.request
SETTINGS=pathlib.Path('/etc/s3-bgp-vip50/settings.json')
def read_health(settings):
    config=pathlib.Path(settings['haproxy_config']).read_text()
    auth=re.search(r'^\s*stats auth (\S+)',config,re.M);assert auth
    request=urllib.request.Request('http://'+settings['local_ip']+':1968/stats;csv',headers={'Authorization':'Basic '+base64.b64encode(auth.group(1).encode()).decode()})
    opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(request,timeout=2) as r:
        data=r.read(1048577).decode();assert len(data)<=1048576 and data.startswith('# pxname,')
    rows=list(csv.DictReader(io.StringIO(data[2:])))
    front=[r for r in rows if r.get('pxname')=='frontend' and r.get('svname')=='FRONTEND']
    back=[r for r in rows if r.get('pxname')=='backend' and r.get('svname','').startswith('rgw.')]
    frontend_open=bool(front) and front[0].get('status')=='OPEN'
    backend_up=any(r.get('status','').split()[0]=='UP' for r in back if r.get('status'))
    # Conservative: advertise this ingress only while its own RGW serves S3.
    # This direct health request does not pollute HAProxy's data frontend counter.
    with opener.open('http://127.0.0.1:8080/',timeout=2) as r:
        local_rgw=r.status==200 and b'ListAllMyBucketsResult' in r.read(4096)
    return {'healthy':frontend_open and backend_up and local_rgw,'frontend_open':frontend_open,'backend_up':backend_up,'local_rgw':local_rgw,'frontend_connections':int(front[0].get('stot') or 0) if front else 0,'backends':[{k:r.get(k) for k in ('svname','status','stot')} for r in back]}
def notify(message):
    endpoint=os.environ.get('NOTIFY_SOCKET')
    if not endpoint:return
    if endpoint.startswith('@'):endpoint='\0'+endpoint[1:]
    with socket.socket(socket.AF_UNIX,socket.SOCK_DGRAM) as s:s.connect(endpoint);s.sendall(message.encode())
def network(enabled):
    cmd=['/usr/bin/vtysh','-c','configure terminal','-c','router bgp 65050','-c','address-family ipv4 unicast','-c',('network ' if enabled else 'no network ')+'10.11.4.50/32']
    p=subprocess.run(cmd,stdin=subprocess.DEVNULL,capture_output=True,text=True,timeout=3)
    # FRR 8.4 returns 1 when withdrawing an already absent local network.
    if not enabled and p.returncode==1 and p.stdout.strip()=="% Can't find static route specified" and not p.stderr.strip():return
    if p.returncode or any(x in p.stdout+p.stderr for x in ['% Unknown','% Ambiguous','% Command incomplete']):raise RuntimeError('vtysh failed')
def main():
    p=argparse.ArgumentParser();p.add_argument('--withdraw',action='store_true');p.add_argument('--check',action='store_true');a=p.parse_args()
    settings=json.loads(SETTINGS.read_text());assert settings['vip']=='10.11.4.50/32' and settings['asn']==65050
    assert socket.gethostname()=='nettest-'+settings['local_ip'].rsplit('.',1)[1]
    if a.check:print(json.dumps(read_health(settings)));return
    if a.withdraw:network(False);return
    stopping=False
    def stop(*_):
        nonlocal stopping
        stopping=True
    signal.signal(signal.SIGTERM,stop);signal.signal(signal.SIGINT,stop)
    good=bad=0;enabled=False;previous=None
    try:
        network(False);notify('READY=1\nSTATUS=Waiting for Ceph ingress health')
        while not stopping:
            try:state=read_health(settings)
            except Exception as e:state={'healthy':False,'error_type':type(e).__name__}
            healthy=state['healthy'] and not pathlib.Path('/run/s3-vip50-bgp.disabled').exists()
            if healthy:good+=1;bad=0
            else:bad+=1;good=0
            if good>=3:enabled=True
            if bad>=2:enabled=False
            network(enabled)
            state.update(advertised=enabled,checked_at_unix=time.time(),good=good,bad=bad)
            pathlib.Path('/run/s3-vip50-bgp-health.json').write_text(json.dumps(state)+'\n')
            if enabled!=previous:print('VIP50 /32 '+('advertised' if enabled else 'withdrawn'),flush=True);previous=enabled
            notify('WATCHDOG=1\nSTATUS='+('VIP50 advertised' if enabled else 'VIP50 withdrawn'))
            time.sleep(2)
    finally:network(False)
if __name__=='__main__':main()
