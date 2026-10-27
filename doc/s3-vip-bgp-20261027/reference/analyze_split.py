"""Correlate source ports; incomplete capture remains a failed test, with diagnostics."""
import argparse,json,sys
from pathlib import Path

class AnalysisError(ValueError):
    def __init__(self,message,details=None):
        super().__init__(message);self.details=details or {}

def require(condition,message,details=None):
    if not condition:raise AnalysisError(message,details)

def read(path):
    wrapper=json.loads(path.read_text(encoding='utf-8'))
    require(wrapper['exit_code']==0,'Remote program failed: '+str(path))
    return json.loads(wrapper['stdout'])

def analyze(probe,left,right):
    requests=probe['requests']
    require(len(requests)==64 and all(x['status']==200 and x['s3_xml'] for x in requests),'Need 64 successful S3 HTTP responses')
    ports={x['source_port'] for x in requests}
    require(len(ports)==64,'Source ports reused; rerun in a fresh window')
    require('via 10.11.4.1' in probe['route'],'VM40 source route did not use the Leaf')
    require(not probe['remaining_exact_route'] and probe['restored_redirects']==probe['original_redirects'],'VM40 cleanup incomplete')
    require(left['hostname']=='nettest-41' and right['hostname']=='nettest-42','Unexpected capture hosts')
    require(left['gateway_mac']==right['gateway_mac'],'Gateway MAC differs between capture nodes')
    run_ids=[x.get('run_id') for x in (probe,left,right)]
    require(not any(run_ids) or bool(run_ids[0]) and len(set(run_ids))==1,'Files belong to different test runs')
    seen=[{x['source_port'] for x in c['unique_syn_flows']} & ports for c in (left,right)]
    details={'http_successes':64,'matched_ingress_connections':{'10.11.4.41':len(seen[0]),'10.11.4.42':len(seen[1])},'missing_source_ports':sorted(ports-(seen[0]|seen[1])),'duplicate_source_ports':sorted(seen[0]&seen[1]),'capture_windows':{}}
    for capture in (left,right):
        require(capture['passive_capture'] and not capture['promiscuous_mode'],'Expected passive ingress capture')
        details['capture_windows'][capture['hostname']]={'started_relative_to_probe_seconds':round(capture['started_unix']-probe['started_unix'],3),'ended_relative_to_probe_end_seconds':round(capture['finished_unix']-probe['finished_unix'],3)}
    incomplete=[host for host,window in details['capture_windows'].items() if window['started_relative_to_probe_seconds']>2 or window['ended_relative_to_probe_end_seconds'] < -2]
    require(not incomplete,'Capture did not cover the complete probe window: '+', '.join(incomplete)+'. Rerun run_split_test.py to synchronize both captures before the probe.',details)
    require(seen[0] and seen[1],'One ingress received no matched test connections',details)
    require(not seen[0]&seen[1],'A TCP flow moved or was seen at both ingresses; steady-state test did not pass',details)
    require(seen[0]|seen[1]==ports,'Missing ingress evidence for some successful requests; rerun with complete capture coverage',details)
    return {'verdict':'PASS',**details,'run_id':run_ids[0],'gateway_source_mac':left['gateway_mac'],'source_route_restored':True,'meaning':'Both ingress VMs received distinct routed test TCP connections; exact 50/50 is not required.'}

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--probe',type=Path,required=True);parser.add_argument('--left',type=Path,required=True);parser.add_argument('--right',type=Path,required=True);parser.add_argument('--output',type=Path,required=True);args=parser.parse_args()
    try:result=analyze(read(args.probe),read(args.left),read(args.right))
    except (AnalysisError,KeyError,TypeError,OSError,ValueError) as error:
        result={'verdict':'FAIL','error':str(error),**getattr(error,'details',{})}
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(result,ensure_ascii=True,indent=2))
    return 0 if result['verdict']=='PASS' else 1
if __name__=='__main__':sys.exit(main())
