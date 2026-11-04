"""Read-only manifest/ANSI port comparison of the validated native runner."""
import ast
import hashlib
import json
import re
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]
HERE=ROOT/'sim/experiments/npu_full_native'

def ports(path):
    s=re.sub(r'//[^\n]*|/\*.*?\*/','',path.read_text(),flags=re.S)
    m=re.search(r'\bmodule\s+\w+',s); pos=m.end()
    def group(pos):
        pos=s.index('(',pos); start=pos; depth=1;pos+=1
        while depth:
            depth+=(s[pos]=='(')-(s[pos]==')');pos+=1
        return s[start+1:pos-1],pos
    if s[pos:].lstrip().startswith('#'):
        _,pos=group(pos)
    header,_=group(pos)
    out={};direction=None
    for item in header.split(','):
        d=re.search(r'\b(input|output|inout)\b',item)
        if d:direction=d.group(1)
        tokens=re.findall(r'[A-Za-z_]\w*',re.sub(r'\[[^]]*\]',' ',item))
        if tokens and direction:out[tokens[-1]]=direction
    return out

def main():
    tree=ast.parse((HERE/'run.py').read_text())
    fn=next(n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name=='main')
    env={'ROOT':ROOT,'HERE':HERE};rtl=[]
    for n in fn.body:
        if isinstance(n,ast.Assign) and any(isinstance(x,ast.Name) and x.id=='rtl' for x in n.targets):
            rtl=eval(compile(ast.Expression(n.value),'<rtl>','eval'),env)
        elif isinstance(n,ast.AugAssign) and isinstance(n.target,ast.Name) and n.target.id=='rtl':
            rtl+=eval(compile(ast.Expression(n.value),'<rtl>','eval'),env)
    result=[]
    for p in rtl:
        module=re.search(r'\bmodule\s+(\w+)',p.read_text()).group(1)
        matches=list((ROOT/'src').rglob(module+'.v'))
        production=matches[0] if len(matches)==1 else None
        cp=ports(p);pp=ports(production) if production else {}
        result.append({'module':module,'validated_source':p.relative_to(ROOT).as_posix(),
            'sha256':hashlib.sha256(p.read_bytes()).hexdigest(),
            'production_source':production.relative_to(ROOT).as_posix() if production else None,
            'identical_to_production':p.read_bytes()==production.read_bytes() if production else False,
            'ports_added':{k:v for k,v in cp.items() if k not in pp},
            'ports_removed':{k:v for k,v in pp.items() if k not in cp}})
    out=ROOT/'build/sim/npu_integration_review';out.mkdir(parents=True,exist_ok=True)
    (out/'manifest.json').write_text(json.dumps(result,indent=2)+'\n',encoding='ascii')
    for row in result:
        print(row['module']+': '+row['validated_source'])
        print('  production='+str(row['production_source'])+' identical='+str(row['identical_to_production'])+' added='+str(row['ports_added'])+' removed='+str(row['ports_removed']))
    print('RESULT: manifest generated from '+str(len(result))+' actual runner RTL inputs; no source writes')
if __name__=='__main__':main()
