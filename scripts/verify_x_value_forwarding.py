#!/usr/bin/env python3
"""Independent actual-stage proof of visible RAM/X equality for R28.

Consumes trace manifests whose complete PRGs equal the production pin. Resolves
storage and aliases with 64tass, then uses symbolic byte values/versions, rather
than the compiler's register-to-cell facts. No inferred pre-X stage is accepted.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import verify_dead_call_writes as dse

OPCODES=dse.storage.OPCODES
MEM=set('adc and asl bit cmp cpx cpy dec eor inc lda ldx ldy lsr ora rol ror sbc sta stx sty'.split())
WRITE=set('sta stx sty asl lsr rol ror inc dec'.split())
AWRITE=set('adc and eor ora sbc asl lsr rol ror pla'.split())
BARRIER=set('bcc bcs beq bmi bne bpl bvc bvs jmp jsr rts rti brk pha php pla plp tsx txs cli sei cld sed'.split())


def digest(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def assembled(path,out,tass):
    """Insert byte-free extent labels; independently check identical PRG bytes."""
    out.mkdir(parents=True,exist_ok=True);raw=Path(path).read_text();frames=[];all_sections=[];active=None;domain=0;annotated=[];in_asm=False
    for i,line in enumerate(raw.splitlines()):
        s=line.strip()
        if s.startswith('; inline asm'):in_asm=True
        if s=='; end inline asm':in_asm=False
        if s.startswith('* = ') or s.startswith('.logical '):domain+=1
        if not in_asm and s.startswith('; zeropage_section_begin '):
            fields=dict(re.findall(r'(\w+)=([^\s]+)',s))
            assert active is None
            active=dict(**fields,domain=domain,first=i,last=None,names=[]);all_sections.append(active)
            if fields['kind'] in ('static_frame','scratch','rodata'):frames.append(active)
            annotated.append('xqa_extent_'+str(len(all_sections))+'_begin:')
        if active is not None:
            if m:=dse.LABEL.fullmatch(s):active['names'].append(m[1])
        annotated.append(line)
        if not in_asm and s.startswith('; zeropage_section_end ') and active is not None:
            active['last']=i;annotated.append('xqa_extent_'+str(len(all_sections))+'_end:');active=None
    assert active is None
    prg=out/'stage.prg';ins=out/'inspect.prg';src=out/'inspect.asm';src.write_text('\n'.join(annotated)+'\n')
    for source,target in [(Path(path),prg),(src,ins)]:
        cmd=[str(tass),'-q','--cbm-prg','--vice-labels','-l',str(target)+'.labels','-o',str(target),str(source)]
        r=subprocess.run(cmd,capture_output=True,text=True);assert r.returncode==0,(cmd,r.stdout,r.stderr)
    assert prg.read_bytes()==ins.read_bytes(),'extent labels changed emitted bytes'
    labels=dse.labels_for(ins);model={};sections=[]
    for index,f in enumerate(all_sections,1):
        lo=labels['xqa_extent_'+str(index)+'_begin'];hi=labels['xqa_extent_'+str(index)+'_end']
        assert hi>=lo
        f.update(start=lo,end=hi,size=hi-lo)
        if f in frames:
            for name in f['names']:
                assert name not in model
                model[name]=(frames.index(f)+1,labels[name]-lo)
        sections.append(dict(owner=f['owner'],kind=f['kind'],start=lo,end=hi,size=hi-lo,labels=f['names']))
    Path(str(prg)+'.asm').write_text(raw)
    # Stage maps carry independently resolved source/storage extents, no claims.
    Path(str(prg)+'.zpmap.json').write_text(json.dumps({'sections':sections}))
    return dict(path=str(prg),raw=raw,frames=frames,model=model,labels=labels,extent_prg_identical=True)


def verify_forwarding(before,after,model):
    bl=before.splitlines();al=after.splitlines();assert len(bl)==len(al),'X pass changed line count'
    frames=model['frames'];defs=model['model'];memory={};serial=0;regs={};changes=[];active=False;in_asm=False
    def fresh():
        nonlocal serial
        serial+=1;return serial
    def reset():
        memory.clear();regs.update(A=fresh(),X=fresh(),Y=fresh())
    def resolve(operand):
        m=re.fullmatch(r'([A-Za-z_][A-Za-z_0-9]*)(?:\s*([+-])\s*(\d+|\$[0-9a-fA-F]+))?',operand)
        if not m or m[1] not in defs:return None
        f,off=defs[m[1]];off+=(dse.storage.integer(m[3])*(1 if m[2]=='+' else -1)) if m[3] else 0
        frame=frames[f-1]
        if not 0<=off<frame['size'] or not (0x200<=frame['start']<=frame['end']<=0xa000 or 0xc000<=frame['start']<=frame['end']<=0xd000):return None
        return f,off
    def value(cell):
        if cell not in memory:memory[cell]=fresh()
        return memory[cell]
    reset()
    for index,(b,a) in enumerate(zip(bl,al)):
        s=b.strip();changed=b!=a
        if s.startswith('; inline asm'):in_asm=True;reset()
        elif in_asm:
            if s=='; end inline asm':in_asm=False
            reset()
        elif s.startswith('; zeropage_section_begin '):
            active='owner=function:' in s and 'kind=code' in s;reset()
        elif s.startswith('; zeropage_section_'):active=False;reset()
        elif active:
            parts=s.split(None,1);op=parts[0].lower() if parts else '';operand=parts[1] if len(parts)>1 else ''
            cell=resolve(operand)
            if changed:
                assert op=='lda' and a.strip()=='txa',(index+1,'non-LDA/TXA rewrite',b,a)
                assert cell is not None and regs['X']==value(cell),(index+1,'X differs from target byte',b,regs,memory)
                changes.append(dict(line=index+1,original=s,replacement='txa',frame=cell[0],offset=cell[1],address=frames[cell[0]-1]['start']+cell[1]))
            if op not in OPCODES or op in BARRIER:reset()
            elif op in MEM and operand.lower()!='a' and not operand.startswith('#'):
                if cell is None:reset()
                elif op in ('lda','ldx','ldy'):regs[op[-1].upper()]=value(cell)
                elif op in WRITE:
                    # Separately originated domains might alias. Any write makes
                    # their previous memory versions unknown, without pretending
                    # to alter register byte values already held by the CPU.
                    domain=frames[cell[0]-1]['domain']
                    for other in list(memory):
                        if frames[other[0]-1]['domain']!=domain:memory[other]=fresh()
                    memory[cell]=regs[op[-1].upper()] if op in ('sta','stx','sty') else fresh()
                elif op in AWRITE:regs['A']=fresh()
            elif op in ('lda','ldx','ldy'):regs[op[-1].upper()]=fresh()
            elif op=='tax':regs['X']=regs['A']
            elif op=='txa':regs['A']=regs['X']
            elif op=='tay':regs['Y']=regs['A']
            elif op=='tya':regs['A']=regs['Y']
            elif op in ('inx','dex'):regs['X']=fresh()
            elif op in ('iny','dey'):regs['Y']=fresh()
            elif op in AWRITE:regs['A']=fresh()
        else:reset()
        if changed:assert active and not in_asm,(index+1,'rewrite outside typed code/inside ASM')
    return changes


def verify_manifest(manifest,out,tass):
    data=json.loads(Path(manifest).read_text());assert data['status']=='success';rows=[]
    for n,row in enumerate(data['rows']):
        assert row['exact_identity']
        for key in ('trace_prg','pinned_prg','actual_after_prg'):assert digest(row[key]['path'])==row[key]['sha256']
        assert row['trace_prg']['sha256']==row['pinned_prg']['sha256']==row['actual_after_prg']['sha256']
        paths=row['stages']
        for m in paths.values():assert digest(m['path'])==m['sha256']
        pre=assembled(paths['pre-x.asm']['path'],out/str(n)/'pre-x',tass)
        changes=verify_forwarding(pre['raw'],Path(paths['post-x.asm']['path']).read_text(),pre)
        if row['gate']!='enabled':assert not changes
        post=assembled(paths['post-x.asm']['path'],out/str(n)/'post-x',tass)
        inv=dse.inventory(Path(post['path']))
        rows.append(dict(source=row['source'],source_sha256=row['source_sha256'],actual_after_prg=row['actual_after_prg'],stages=paths,forwarded=changes,post_x_inventory_path=post['path'],post_x_capture_masks={name:dict(read_mask=v['read_mask'],eligible=v['eligible']) for name,v in inv['cells'].items()},extent_prg_identical=True))
    report=dict(format='zeropage-x-forwarding-stage-proof-v1',status='success',manifest=str(manifest),manifest_sha256=digest(manifest),artifacts=len(rows),forwarded=sum(len(r['forwarded']) for r in rows),rows=rows,scope='Actual triple-PRG-identical pipeline stages only. Independent 64tass physical extent/alias resolution and symbolic byte/version equality before every LDA-to-TXA substitution. Comments/labels/stack/unknown/ASM barriers reset; ROM/MMIO and cross-domain writes invalidate facts. Downstream DSE/lifecycle/native proofs recorded separately.')
    (out/'forwarding-proof.json').write_text(json.dumps(report,indent=2)+'\n');return report


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--manifest',type=Path,required=True);p.add_argument('--output-dir',type=Path,required=True);p.add_argument('--tass',type=Path,required=True);a=p.parse_args();a.output_dir.mkdir(parents=True,exist_ok=True);r=verify_manifest(a.manifest,a.output_dir,a.tass);print('PASS',r['artifacts'],'actual stages;',r['forwarded'],'independently proved forwards')

if __name__=='__main__':main()
