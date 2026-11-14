#!/usr/bin/env python3
"""Independent byte-read/store and layout proof for R27 private capture DSE.

Permits only proven never-read private STA/STX/STY deletions and subsequent dead
capture declarations. Verified ZP bindings may rerank/promote; lifecycle effects
are independently checked against policy/claims in real Peddle execution. No user
instruction, producer, call, RMW or source/formal object may disappear.
"""
import argparse
import collections
import ctypes as c
import difflib
import hashlib
import json
from pathlib import Path
import re

import verify_dead_call_storage as storage
from verify_pointer_reuse import Image

CANONICAL=storage.CANONICAL
LABEL=storage.LABEL
STORES={'sta','stx','sty'}
READS=set('adc and asl bit cmp cpx cpy dec eor inc lda ldx ldy lsr ora rol ror sbc'.split())
FIXED={'pointer','string_pointer','stack_pointer','frame_pointer'}


def digest(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def labels_for(path):
    p=Path(str(path)+'.labels')
    return {m[2]:int(m[1],16) for line in p.read_text().splitlines() if (m:=re.fullmatch(r'al ([0-9a-fA-F]+) \.(.+)',line))} if p.exists() else {}


def alias(text):return re.fullmatch(r'([A-Za-z_][A-Za-z_0-9]*) = address\(\$([0-9a-fA-F]+)\)',text)


def direct(text):
    parts=text.split(None,1)
    if len(parts)!=2:return None
    m=re.fullmatch(r'([A-Za-z_][A-Za-z_0-9]*)(?:\s*([+-])\s*([0-9]+|\$[0-9a-fA-F]+))?',parts[1])
    if not m:return None
    offset=storage.integer(m[3])*(1 if m[2]=='+' else -1) if m[3] else 0
    return parts[0].lower(),m[1],offset


def inventory(path):
    parsed=storage.parse(str(path)+'.asm');mapping=json.loads(Path(str(path)+'.zpmap.json').read_text());labels=labels_for(path)
    claims={v['label']:v for v in mapping.get('zero_page',{}).get('claims',[])}
    cells={};decl_lines={}
    for position,(i,text) in enumerate(parsed[1]):
        if parsed[3][i]!=('compiler','scratch'):continue
        name=None;word=None
        if m:=LABEL.fullmatch(text):
            name=m[1]
            following=parsed[1][position+1] if position+1<len(parsed[1]) else None
            if not following or following[1]!='.word 0':continue
            word=following[0]
        elif m:=alias(text):
            name=m[1]
            if not CANONICAL.fullmatch(name):continue
            cl=claims.get(name)
            assert cl and cl['addr']==int(m[2],16) and cl['size']==2,(path,name,'invalid claimed alias')
        if not name or not CANONICAL.fullmatch(name):continue
        assert name not in cells,(path,name,'duplicate capture definition')
        cells[name]=dict(label=name,size=2,read_mask=0,stores=[],label_line=i,word_line=word)
        decl_lines[i]=name
    escapes=storage.family_escapes(parsed,mapping,labels)
    guarded='; inline asm' in Path(str(path)+'.asm').read_text() or bool(mapping.get('memory_placements')) or 'zeropage_module_reloc_' in Path(str(path)+'.asm').read_text()
    # Every canonical reference must correspond to a real, verified capture.
    for i,text in parsed[1]:
        if i in decl_lines:continue
        tokens=set(re.findall(r'\bzeropage_call_arg_[0-9]+\b',text,re.I))
        if not tokens:continue
        ref=direct(text)
        for token in tokens:
            name=next((n for n in cells if n.lower()==token.lower()),None)
            if name is None:
                escapes.append(dict(line=i+1,text=text,kind='undefined_capture'));continue
            if not ref or ref[1].lower()!=name.lower() or not 0<=ref[2]<2 or ref[0] not in READS|STORES:
                escapes.append(dict(line=i+1,text=text,kind='non_direct_capture_reference'));cells[name]['read_mask']=3;continue
            op,_,offset=ref
            if op in READS:cells[name]['read_mask']|=1<<offset
            if op in STORES:cells[name]['stores'].append(dict(line=i,op=op,offset=offset,text=text))
    safe=not escapes and not guarded
    for name,cell in cells.items():
        # Co-located compiler aliases expose the same physical cell.
        cell['eligible']=safe
        if name in labels:
            for other,indices in parsed[2].items():
                if other!=name and other in labels and labels[other]==labels[name] and any(parsed[3][i]==('compiler','scratch') for i in indices):cell['eligible']=False
    return dict(path=path,parsed=parsed,mapping=mapping,labels=labels,claims=claims,cells=cells,escapes=escapes,guarded=guarded,family_safe=safe)


def groups(mask):
    values=sorted(mask);out=[]
    for a in values:
        if not out or a!=out[-1][-1]+1:out.append([a])
        else:out[-1].append(a)
    return out


def validate_lifecycle(facts,lib):
    """Check actual CPU/memory effects, not a copied expected instruction emitter."""
    path=facts['path'];parsed=facts['parsed'];info=facts['mapping'].get('zero_page',{});claims=facts['claims'];labels=facts['labels'];skip=set();texts=[]
    owned=set();initialized=set()
    for cl in claims.values():
        slots=set(range(cl['addr'],cl['addr']+cl['size']));assert not owned&slots and slots<=set(range(2,256));owned|=slots
        if cl['kind'] in ('scratch','parameter'):initialized|=slots
    restored=owned&set(range(2,0x90 if info.get('profile')=='kernal' else 0xfb)) if info.get('restore_basic') and info.get('profile') in ('kernal','bare') else set()
    assert len(owned)==info.get('owned_bytes',len(owned)) and len(restored)==info.get('restored_bytes',len(restored))
    stated={a for r in info.get('restored_ranges',[]) for a in range(r['addr'],r['addr']+r['size'])};assert restored==stated
    for r in info.get('reserved_ranges',[]):assert not owned&set(range(r['addr'],r['addr']+r['size']))
    expected=bool(initialized or restored);assert bool(info.get('entry_lifecycle',False))==expected
    # Only the exact generated wrapper is normalized; source main stays intact.
    meaningful=parsed[1]
    for pos,(i,text) in enumerate(meaningful):
        if text=='zeropage_entry:' and expected:
            wrapper=meaningful[pos+1:pos+4];assert [t for _,t in wrapper]==['jsr zeropage_zp_enter','jsr main','jmp zeropage_zp_leave'];skip.update(j for j,_ in wrapper);texts.extend(t for _,t in wrapper)
    if not expected:
        assert 'zeropage_zp_enter' not in labels and 'zeropage_zp_leave' not in labels
        return skip,texts,dict(owned=len(owned),initialized=0,restored=0,executions=0)
    start=next(i for i,t in meaningful if t=='zeropage_zp_enter:')
    end=next(i for i in range(start,len(parsed[0])) if parsed[0][i].strip().startswith('; zeropage_section_end '))
    body=[(i,t) for i,t in meaningful if start<=i<end];skip.update(i for i,_ in body);texts.extend(t for _,t in body)
    snapshot=labels.get('zeropage_zp_snapshot');size=len(restored)
    if size:
        pos=next(k for k,(_,t) in enumerate(meaningful) if t=='zeropage_zp_snapshot:');items=meaningful[pos:pos+2];assert items[1][1]==f'.fill {size},0';skip.update(i for i,_ in items);texts.extend(t for _,t in items)
    else:assert snapshot is None
    assert lib is not None,'Peddle --library required for validated lifecycle changes'
    im=Image(lib,path);m=im.machine
    # Accepted opcodes are a simple deterministic memory-copy/counter ABI. No
    # calls, arbitrary arithmetic, RMW, mode changes or hidden branches admitted.
    widths={0x08:1,0x48:1,0x8a:1,0x98:1,0x68:1,0xa8:1,0xaa:1,0x28:1,0x60:1,0xa2:2,0xa9:2,0xa5:2,0xb5:2,0xad:3,0xbd:3,0x85:2,0x95:2,0x8d:3,0x9d:3,0xe8:1,0xe0:2,0xd0:2}
    executions=0
    try:
        for seed,status in ((0x35,0x20),(0xa6,0xef)):
            initial=bytes((a*73+seed)&255 for a in range(256));initialregs=(0x23,0x89,0x67,status,0xf9)
            for a,v in enumerate(initial):im.write(m,a,v)
            for stage in ('enter','leave'):
                if stage=='leave':
                    for a in owned:im.write(m,a,(a^0x5a)&255)
                im.reset(m);im.set_pc(m,labels['zeropage_zp_'+stage]);im.set_sp(m,0xf9);im.set_a(m,initialregs[0]);im.set_x(m,initialregs[1]);im.set_y(m,initialregs[2]);im.set_p(m,status)
                writes=collections.Counter();reads=collections.Counter();previous=None
                for _ in range(10000):
                    r=im.regs(m);op=im.read(m,r.pc);assert op in widths,(path,stage,'unexpected lifecycle opcode',op)
                    assert 0xf5<=r.sp<=0xf9
                    if op==0x60 and r.sp==0xf9:break
                    if op==0xd0:assert previous==0xe0,(path,'lifecycle branch not controlled by counter CMP')
                    if op in (0xa2,):assert im.read(m,r.pc+1)==0
                    if op==0xa9:assert im.read(m,r.pc+1)==0
                    if op in (0xa5,0xb5,0xad,0xbd,0x85,0x95,0x8d,0x9d):
                        address=im.read(m,r.pc+1)|(im.read(m,r.pc+2)<<8 if widths[op]==3 else 0)
                        if op in (0xb5,0x95,0xbd,0x9d):address=(address+r.x)&(255 if widths[op]==2 else 65535)
                        store=op in (0x85,0x95,0x8d,0x9d)
                        if store:
                            valid=(address in initialized or (snapshot is not None and snapshot<=address<snapshot+size)) if stage=='enter' else address in restored
                            assert valid,(path,stage,'out-of-plan write',address);writes[address]+=1
                        else:
                            valid=address in restored if stage=='enter' else snapshot is not None and snapshot<=address<snapshot+size
                            assert valid,(path,stage,'out-of-plan read',address);reads[address]+=1
                    previous=op;im.step(m)
                else:raise AssertionError((path,'lifecycle budget'))
                assert (r.a,r.x,r.y,r.p,r.sp)==initialregs,(path,stage,'AXYP/SP not preserved')
                expectedwrites=initialized|set(range(snapshot,snapshot+size)) if stage=='enter' and snapshot is not None else initialized if stage=='enter' else restored
                assert set(writes)==expectedwrites and all(n==1 for n in writes.values()),(path,stage,'write footprint')
                for a in range(256):
                    expectedvalue=(0 if a in initialized else initial[a]) if stage=='enter' else (initial[a] if a in restored or a not in owned else (a^0x5a)&255)
                    assert im.read(m,a)==expectedvalue,(path,stage,'ZP oracle',a)
                if stage=='enter' and snapshot is not None:assert bytes(im.read(m,snapshot+i) for i in range(size))==bytes(initial[a] for a in sorted(restored))
                executions+=1
    finally:im.close()
    return skip,texts,dict(owned=len(owned),initialized=len(initialized),restored=size,executions=executions)


def verify_pair(before,after,lib):
    b=inventory(before);a=inventory(after);removed=set(b['cells'])-set(a['cells']);assert not set(a['cells'])-set(b['cells'])
    for name in removed:assert b['cells'][name]['eligible'] and b['cells'][name]['read_mask']==0,(before,name,'observable/escaped capture removed')
    for name in set(b['cells'])&set(a['cells']):assert b['cells'][name]['read_mask']==a['cells'][name]['read_mask'],(before,name,'read mask changed')
    # Claim roles/widths persist; physical addresses/benefits may rerank, and only
    # dead capture objects may disappear. Newly promoted existing source objects
    # are checked by declaration normalization and unchanged parameter facts.
    for name in set(b['claims'])&set(a['claims']):
        x,y=b['claims'][name],a['claims'][name];assert (x['kind'],x['size'])==(y['kind'],y['size'])
        if x['kind'] in FIXED:assert x['addr']==y['addr']
    for facts in (b,a):
        info=facts['mapping'].get('zero_page',{});params={v['label']:(v['size'],v['reason']) for v in info.get('parameters',[])}
        for cl in facts['claims'].values():
            if cl['kind']=='parameter':assert params.get(cl['label'])==(cl['size'],'eligible')
    bp={v['label']:(v['size'],v['reason']) for v in b['mapping'].get('zero_page',{}).get('parameters',[])};ap={v['label']:(v['size'],v['reason']) for v in a['mapping'].get('zero_page',{}).get('parameters',[])};assert bp==ap
    ever=set(b['claims'])|set(a['claims']);kind={n:(b['claims'].get(n) or a['claims'][n])['kind'] for n in ever};sizes={n:(b['claims'].get(n) or a['claims'][n])['size'] for n in ever}
    normalized=[];life=[]
    for facts in (b,a):
        skip,lifetext,lifereport=validate_lifecycle(facts,lib);life.append((lifetext,lifereport));decltokens={};meaning=facts['parsed'][1]
        for pos,(i,text) in enumerate(meaning):
            m=alias(text);name=m[1] if m else (LABEL.fullmatch(text)[1] if LABEL.fullmatch(text) else None)
            if name not in ever|removed:continue
            if m:
                cl=facts['claims'].get(name);assert cl and int(m[2],16)==cl['addr'];decl=[i]
            else:
                if name not in ever and name not in removed:continue
                nxt=meaning[pos+1] if pos+1<len(meaning) else None;assert nxt
                expectedsize=sizes.get(name,2);assert nxt[1]==('.byte 0' if expectedsize==1 else '.word 0') or expectedsize==2 and nxt[1]=='.byte 0,0',(facts['path'],name,'unexpected initializer/width');decl=[i,nxt[0]]
            if name in removed:skip.update(decl);continue
            role=facts['parsed'][3][i]
            if kind[name]=='parameter':assert role and role[0].startswith('function:') and role[1]=='static_frame'
            if kind[name]=='scratch':assert role==('compiler','scratch')
            decltokens[i]=f'VERIFIED_OBJECT {name} {kind[name]} {sizes[name]}';skip.update(decl[1:])
        tokens=[]
        for i,text in meaning:
            if i in skip:continue
            tokens.append((decltokens.get(i,text),i))
        normalized.append(tokens)
    bc={(n,v['addr'],v['size'],v['kind']) for n,v in b['claims'].items()};ac={(n,v['addr'],v['size'],v['kind']) for n,v in a['claims'].items()}
    if bc==ac:assert life[0][0]==life[1][0],(before,'unnecessary lifecycle text change')
    allowed={w['line']:dict(label=n,**w) for n,v in b['cells'].items() if v['eligible'] for w in v['stores'] if not v['read_mask']&(1<<w['offset'])};deleted=[]
    seq=difflib.SequenceMatcher(a=[t for t,_ in normalized[0]],b=[t for t,_ in normalized[1]],autojunk=False)
    for tag,i,j,k,l in seq.get_opcodes():
        if tag=='equal':continue
        assert tag=='delete',(before,after,'unapproved instruction/data change',tag,normalized[0][i:j],normalized[1][k:l])
        for text,line in normalized[0][i:j]:assert line in allowed,(before,'unapproved deletion',text);deleted.append(allowed[line])
    for name in {r['label'] for r in deleted}|removed:
        addr=b['labels'].get(name);assert addr is not None,(before,name,'unknown physical capture binding')
        claim=b['claims'].get(name)
        if claim:assert claim['kind']=='scratch' and claim['size']==2 and claim['addr']==addr and 2<=addr<=254
        else:assert 0x200<=addr and addr+2<=0x10000 and (addr+2<=0xd000 or addr>=0xe000),(before,name,'capture is not ordinary write-through RAM')
        for section in b['mapping'].get('sections',[]):
            if section.get('start') is None or section.get('end') is None or not section.get('size'):continue
            if section['owner']=='compiler' and section['kind']=='scratch' and name in section['labels']:continue
            assert addr+2<=section['start'] or section['end']<=addr,(before,name,'capture overlaps other code/source/data ownership',section['owner'],section['kind'])
    for name in removed:assert all(w['line'] in {v['line'] for v in deleted} for w in b['cells'][name]['stores'])
    if b['guarded']:assert before.read_bytes()==after.read_bytes() and not deleted and not removed
    return dict(before=str(before),after=str(after),before_sha256=digest(before),after_sha256=digest(after),before_bytes=before.stat().st_size,after_bytes=after.stat().st_size,
                stores_removed=deleted,words_removed=sorted(removed),read_masks={n:v['read_mask'] for n,v in b['cells'].items()},family_safe=b['family_safe'],family_escapes=b['escapes'],
                validated_lifecycle={'before':life[0][1],'after':life[1][1]},claims_added=sorted(set(a['claims'])-set(b['claims'])),claims_removed=sorted(set(b['claims'])-set(a['claims'])),
                source_parameter_facts_identical=True,other_meaningful_code_data_identical=True,guarded_binary_identical=b['guarded'])


def main():
    p=argparse.ArgumentParser(description=__doc__)
    for name in ('before','after'):p.add_argument('--'+name,type=Path,action='append',required=True)
    p.add_argument('--library',type=Path,required=True);p.add_argument('--output',type=Path,required=True);args=p.parse_args();lib=c.CDLL(str(args.library.resolve()))
    bs=[x for d in args.before for x in d.rglob('*.prg')];aa=[x for d in args.after for x in d.rglob('*.prg')];b={x.name:x for x in bs};a={x.name:x for x in aa};assert len(b)==len(bs) and len(a)==len(aa) and b.keys()==a.keys()
    rows=[verify_pair(b[n],a[n],lib) for n in sorted(b)];report=dict(format='zeropage-r27-dead-call-writes-symbolic-v1',status='success',artifacts=len(rows),changed=sum(bool(r['stores_removed'] or r['words_removed']) for r in rows),stores_removed=sum(len(r['stores_removed']) for r in rows),words_removed=sum(len(r['words_removed']) for r in rows),rows=rows,
        scope='Only guarded canonical capture STA/STX/STY bytes with zero global readmask may disappear, followed by unused words. RMW counts as read. Verified logical declarations may move between resident and claimedZP storage; source/formal identities/type facts persist. Lifecycle ABI/memory effects independently executed against policy masks, then only that validated generated region is normalized. No producer/call/volatile/RMW/user instruction deletion or blanketCPU/RAM normalization.')
    args.output.write_text(json.dumps(report,indent=2)+'\n');print('PASS',report['artifacts'],'pairs;',report['stores_removed'],'stores;',report['words_removed'],'words')


if __name__=='__main__':main()
