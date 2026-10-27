"""Install reviewed VM-side VIP50 BGP files; preserve cephadm HAProxy and Keepalived."""
import getpass,importlib.util,json
from pathlib import Path
root=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('runner',root/'vm_runner.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
password=getpass.getpass('Physical server SSH password (not saved): ')
for ip in ['10.11.4.41','10.11.4.42']:
    baseline=json.loads((root/'baseline'/('vm-'+ip+'.json')).read_text(encoding='utf-8'))['data']
    config=baseline['ingress_metadata'][0]['config']
    frr=f'''frr defaults traditional
hostname nettest-{ip.rsplit('.',1)[1]}
log syslog informational
service integrated-vtysh-config
!
ip prefix-list S3VIP50-OUT seq 10 permit 10.11.4.50/32
ip prefix-list S3VIP50-OUT seq 100 deny 0.0.0.0/0 le 32
ip prefix-list S3VIP50-IN seq 10 deny 0.0.0.0/0 le 32
!
router bgp 65050
 bgp router-id {ip}
 bgp ebgp-requires-policy
 bgp network import-check
 no bgp default ipv4-unicast
 neighbor 10.11.4.1 remote-as 65000
 neighbor 10.11.4.1 timers 3 9
 address-family ipv4 unicast
  neighbor 10.11.4.1 activate
  neighbor 10.11.4.1 prefix-list S3VIP50-IN in
  neighbor 10.11.4.1 prefix-list S3VIP50-OUT out
 exit-address-family
!
'''
    network_unit='''[Unit]
Description=VIP50 BGP dummy with VRRP ARP compatibility
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/python3 /opt/s3-bgp-vip50/network.py up
ExecStop=/usr/bin/python3 /opt/s3-bgp-vip50/network.py down
[Install]
WantedBy=multi-user.target
'''
    health_unit='''[Unit]
Description=Health-controlled BGP declaration for existing Ceph S3 VIP50
After=network-online.target frr.service s3-vip50-network.service
Wants=frr.service
Requires=s3-vip50-network.service
[Service]
Type=notify
ExecStartPre=/usr/bin/python3 /opt/s3-bgp-vip50/health.py --withdraw
ExecStart=/usr/bin/python3 /opt/s3-bgp-vip50/health.py
ExecStopPost=/usr/bin/python3 /opt/s3-bgp-vip50/health.py --withdraw
WatchdogSec=15s
TimeoutStopSec=10s
Restart=on-failure
RestartSec=3s
MemoryMax=64M
CPUQuota=10%
[Install]
WantedBy=multi-user.target
'''
    files={
      '/opt/s3-bgp-vip50/network.py':(root/'network.py').read_text(encoding='utf-8'),
      '/opt/s3-bgp-vip50/health.py':(root/'health.py').read_text(encoding='utf-8'),
      '/etc/s3-bgp-vip50/settings.json':json.dumps({'vip':'10.11.4.50/32','asn':65050,'local_ip':ip,'haproxy_config':config},indent=2)+'\n',
      '/etc/systemd/system/s3-vip50-network.service':network_unit,
      '/etc/systemd/system/s3-vip50-health.service':health_unit,
      '/etc/systemd/system/frr.service.d/s3-vip50.conf':'[Unit]\nAfter=s3-vip50-network.service\nRequires=s3-vip50-network.service\n[Service]\nMemoryMax=192M\nCPUQuota=20%\n',
      '/etc/sysctl.d/90-s3-bgp-vip50.conf':'# VM enp1s0 only; keep VRRP ARP ownership while dummy VIP is shared\nnet.ipv4.conf.enp1s0.arp_ignore=1\nnet.ipv4.conf.enp1s0.arp_announce=2\n',
    }
    (root/('frr-'+ip+'.conf')).write_text(frr,encoding='utf-8')
    program=r'''
import grp,hashlib,json,os,pathlib,pwd,shutil,subprocess,time
def run(args):
 p=subprocess.run(args,stdin=subprocess.DEVNULL,capture_output=True,text=True,timeout=30)
 assert p.returncode==0,'Command failed: '+repr(args)+' '+p.stderr+' '+p.stdout
 return p.stdout
files=__FILES_PAYLOAD__
assert pathlib.Path('/var/lib/s3-bgp-vip50/before.json').exists()
assert run(['dpkg-query','-W','-f=${Version}','frr']).strip()=='8.4.4-1.1ubuntu6.7'
for name,content in files.items():
 p=pathlib.Path(name)
 known_health_fix=(name=='/opt/s3-bgp-vip50/health.py' and p.exists() and hashlib.sha256(p.read_bytes()).hexdigest()=='bb40e545fec0bea735c767ad700d00116fe656c925a05ebd3fa77fdaa48e76d5')
 assert not p.exists() or p.read_text()==content or known_health_fix,'Refuse overwriting different existing '+name
backup=pathlib.Path('/var/lib/s3-bgp-vip50/frr-package-defaults')
if backup.exists():
 assert pathlib.Path('/etc/frr/frr.conf').read_text()==__FRR_PAYLOAD__,'Existing FRR config differs from this deployment'
else:
 shutil.copytree('/etc/frr',backup)
for name,content in files.items():
 p=pathlib.Path(name);p.parent.mkdir(parents=True,exist_ok=True);p.write_text(content);p.chmod(0o644)
frr=pathlib.Path('/etc/frr/frr.conf');frr.write_text(__FRR_PAYLOAD__);frr.chmod(0o640);os.chown(frr,pwd.getpwnam('frr').pw_uid,grp.getgrnam('frr').gr_gid)
p=pathlib.Path('/etc/frr/daemons');text=p.read_text()
import re
# Ubuntu starts zebra and staticd implicitly; only optional daemons have flags.
for name,value in [('bgpd','yes'),('bfdd','no')]:
 assert re.search(r'^'+name+r'=',text,re.M)
 text=re.sub(r'^'+name+r'=.*$',name+'='+value,text,flags=re.M)
p.write_text(text)
native=run(['/usr/lib/frr/bgpd','-C','-f','/etc/frr/frr.conf'])
run(['systemd-analyze','verify','/etc/systemd/system/s3-vip50-network.service','/etc/systemd/system/s3-vip50-health.service'])
run(['systemctl','daemon-reload'])
run(['systemctl','start','s3-vip50-network.service'])
run(['systemctl','start','frr.service'])
health=json.loads(run(['python3','/opt/s3-bgp-vip50/health.py','--check']));assert health['healthy'],health
routes=json.loads(run(['vtysh','-c','show ip route 10.11.4.50/32 json']))
assert any(x.get('protocol')=='connected' for x in routes.get('10.11.4.50/32',[])),'Exact connected /32 absent'
run(['systemctl','start','s3-vip50-health.service'])
time.sleep(7)
state=json.loads(pathlib.Path('/run/s3-vip50-bgp-health.json').read_text());assert state['advertised'] and state['healthy'],state
run(['systemctl','enable','s3-vip50-network.service','frr.service','s3-vip50-health.service'])
pathlib.Path('/var/lib/s3-bgp-vip50/managed-files.json').write_text(json.dumps(list(files),indent=2)+'\n')
managed=list(files)+['/etc/frr/frr.conf','/etc/frr/daemons']
pathlib.Path('/var/lib/s3-bgp-vip50/managed-sha256.json').write_text(json.dumps({name:hashlib.sha256(pathlib.Path(name).read_bytes()).hexdigest() for name in managed},indent=2)+'\n')
print(json.dumps({'native_bgpd_check':'passed','health':state,'bgp_summary':json.loads(run(['vtysh','-c','show bgp ipv4 unicast summary json'])),'bgp_vip':json.loads(run(['vtysh','-c','show bgp ipv4 unicast 10.11.4.50/32 json'])),'addresses':json.loads(run(['ip','-j','address','show']))}))
'''.replace('__FILES_PAYLOAD__',repr(files)).replace('__FRR_PAYLOAD__',repr(frr))
    compile(program,'<remote-vm-config>','exec')
    result=m.execute_program(ip,program,password,180)
    (root/'execution'/('configure-'+ip+'.json')).write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(ip,'exit_code',result['exit_code'],flush=True)
    if result['exit_code']:
        print(result['stderr'],result['stdout'],flush=True)
        raise SystemExit('VM configuration failed; stop before next VM')
    value=json.loads(result['stdout']);print(json.dumps({'healthy':value['health']['healthy'],'local_prefix':value['bgp_vip'].get('prefix'),'switch_neighbor':value['bgp_summary']},ensure_ascii=True),flush=True)
