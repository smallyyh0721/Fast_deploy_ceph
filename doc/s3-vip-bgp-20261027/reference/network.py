"""VIP50 dummy + per-VM-interface ARP control; never touches the physical host."""
import ipaddress,json,pathlib,subprocess,sys
DEV='s3vip50';VIP='10.11.4.50/32';STATE=pathlib.Path('/var/lib/s3-bgp-vip50/before.json')
def run(*args,check=True):return subprocess.run(args,stdin=subprocess.DEVNULL,capture_output=True,text=True,check=check,timeout=5)
def main():
    assert __import__('socket').gethostname() in ('nettest-41','nettest-42')
    before=json.loads(STATE.read_text())['sysctl'];assert sys.argv[1] in ('up','down')
    existing=run('/usr/sbin/ip','-j','-d','address','show','dev',DEV,check=False)
    if existing.returncode==0:
        link=json.loads(existing.stdout)[0]
        assert link.get('linkinfo',{}).get('info_kind')=='dummy','Not our dummy'
        assert all(a['local']=='10.11.4.50' and a['prefixlen']==32 for a in link.get('addr_info',[]) if a['family']=='inet')
    if sys.argv[1]=='up':
        # Backup nodes must not answer VLAN4 ARP for an address owned only on dummy.
        # The VRRP master still answers because the VIP is also on its enp1s0.
        run('/usr/sbin/sysctl','-w','net.ipv4.conf.enp1s0.arp_ignore=1','net.ipv4.conf.enp1s0.arp_announce=2')
        if existing.returncode:run('/usr/sbin/ip','link','add',DEV,'type','dummy')
        run('/usr/sbin/ip','link','set',DEV,'up')
        run('/usr/sbin/ip','address','replace',VIP,'dev',DEV)
    else:
        if existing.returncode==0:run('/usr/sbin/ip','link','delete',DEV,'type','dummy')
        run('/usr/sbin/sysctl','-w',*[key+'='+str(value) for key,value in before.items()])
    print(json.dumps({'action':sys.argv[1],'dummy':DEV,'vip':VIP,'physical_vrrp_address_untouched':True}))
if __name__=='__main__':main()
