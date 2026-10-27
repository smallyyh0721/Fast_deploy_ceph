"""Bounded passive capture of routed VM40 -> VIP50 TCP SYNs. No promiscuous mode."""
import json,pathlib,socket,struct,subprocess,sys,time

def decode(data,own_mac,gateway_mac):
    if len(data)<54 or data[:6]!=own_mac or data[6:12]!=gateway_mac:return None
    offset=14;protocol=struct.unpack_from('!H',data,12)[0]
    while protocol in (0x8100,0x88a8):
        if len(data)<offset+4:return None
        protocol=struct.unpack_from('!H',data,offset+2)[0];offset+=4
    if protocol!=0x0800 or len(data)<offset+40 or data[offset]>>4!=4:return None
    ihl=(data[offset]&15)*4
    if ihl<20 or len(data)<offset+ihl+20 or data[offset+9]!=6:return None
    if struct.unpack_from('!H',data,offset+6)[0]&0x1fff:return None
    if data[offset+12:offset+16]!=socket.inet_aton('10.11.4.40'):return None
    if data[offset+16:offset+20]!=socket.inet_aton('10.11.4.50'):return None
    tcp=offset+ihl;source_port,destination_port=struct.unpack_from('!HH',data,tcp)
    flags=data[tcp+13]
    if destination_port!=80 or not flags&2 or flags&16:return None
    return {'source_port':source_port,'tcp_sequence':struct.unpack_from('!I',data,tcp+4)[0],'ttl':data[offset+8]}

def main():
    assert socket.gethostname() in ('nettest-41','nettest-42')
    interface='enp1s0';own=pathlib.Path('/sys/class/net',interface,'address').read_text().strip()
    p=subprocess.run(['ip','-j','neigh','show','to','10.11.4.1','dev',interface],stdin=subprocess.DEVNULL,capture_output=True,text=True,timeout=5,check=True)
    neighbors=json.loads(p.stdout);assert len(neighbors)==1 and neighbors[0].get('lladdr'),'Gateway neighbor MAC missing'
    gateway=neighbors[0]['lladdr'];own_mac=bytes.fromhex(own.replace(':',''));gateway_mac=bytes.fromhex(gateway.replace(':',''))
    flows={}
    with socket.socket(socket.AF_PACKET,socket.SOCK_RAW,socket.htons(3)) as s:
        s.bind((interface,0));s.settimeout(.5);started=time.time();deadline=time.monotonic()+60
        print('S3VIP50_CAPTURE_READY',file=sys.stderr,flush=True)
        while time.monotonic()<deadline:
            try:data,address=s.recvfrom(65535)
            except socket.timeout:continue
            if address[2]==socket.PACKET_OUTGOING:continue
            flow=decode(data,own_mac,gateway_mac)
            if flow:
                key=(flow['source_port'],flow['tcp_sequence'])
                if key not in flows:flows[key]={**flow,'first_seen_unix':time.time()}
                if len(flows)>512:raise RuntimeError('Bounded capture limit exceeded')
    print(json.dumps({'hostname':socket.gethostname(),'source':'10.11.4.40','destination':'10.11.4.50:80','interface_mac':own,'gateway_mac':gateway,'started_unix':started,'finished_unix':time.time(),'unique_syn_flows':list(flows.values()),'passive_capture':True,'promiscuous_mode':False,'run_id':globals().get('SPLIT_RUN_ID')}))

if __name__=='__main__':main()
