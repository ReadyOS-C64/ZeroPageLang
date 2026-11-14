#!/usr/bin/env python3
"""Prove that R26 removes only unused canonical compiler call-storage words.

Checks symbolic instructions and every significant assembly line, independently
verifies each deleted declaration's ownership/width/zero uses, and preserves all
other declarations/directives. Native execution is a separate recorded proof.
Accepts private fixture directories or flattened frozen full-corpus directories.
"""
import argparse
import collections
import hashlib
import json
from pathlib import Path
import re

OPCODES = set('adc and asl bcc bcs beq bit bmi bne bpl brk bvc bvs clc cld cli clv cmp cpx cpy dec dex dey eor inc inx iny jmp jsr lda ldx ldy lsr nop ora pha php pla plp rol ror rti rts sbc sec sed sei sta stx sty tax tay tsx txa txs tya'.split())
LABEL = re.compile(r'^([A-Za-z_][A-Za-z_0-9]*):$')
CANONICAL = re.compile(r'^zeropage_call_arg_[0-9]+$')


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def parse(path):
    lines = Path(path).read_text().splitlines()
    meaningful = [(i, line.strip()) for i, line in enumerate(lines) if line.strip() and not line.lstrip().startswith(';')]
    definitions = collections.defaultdict(list)
    context = None
    contexts = {}
    for i, line in enumerate(lines):
        text = line.strip()
        if text.startswith('; zeropage_section_begin '):
            assert context is None, (path, 'nested section', i)
            fields = dict(re.findall(r'(\w+)=([^\s]+)', text));context = (fields['owner'], fields['kind'])
        elif text.startswith('; zeropage_section_end '):
            assert context is not None, (path, 'unbalanced section', i)
            context = None
        contexts[i] = context
        if match := LABEL.fullmatch(text):
            definitions[match[1]].append(i)
    assert context is None, (path, 'open section')
    instructions = [text for _, text in meaningful if text.split()[0].lower() in OPCODES]
    return lines, meaningful, definitions, contexts, instructions


def integer(text):
    text=text.strip()
    return int(text[1:],16) if text.startswith('$') else int(text,10)


def family_escapes(parsed, mapping, labels=None):
    """Independently pin cross-base/index/address escapes, including sibling slots.

    Post-ZP address() declarations are real verified objects, not address-taking.
    Their map widths/addresses establish the same canonical2B bounds as .word0.
    Other compiler scratch objects also cannot legally index beyond their width
    into capture-family storage. Fixed runtime-pointer aliases outside compiler
    scratch sections are not guessed to occupy that relocatable frame.
    """
    lines, meaningful, definitions, contexts, _=parsed
    claims={c['label']:c for c in mapping.get('zero_page',{}).get('claims',[])}
    widths={};decls=set();escapes=[]
    for position,(i,text) in enumerate(meaningful):
        if contexts[i]!=('compiler','scratch'):continue
        match=LABEL.fullmatch(text)
        alias=re.fullmatch(r'([A-Za-z_][A-Za-z_0-9]*) = address\(\$([0-9a-fA-F]+)\)',text)
        if alias:
            name=alias[1];claim=claims.get(name)
            assert claim and claim['addr']==int(alias[2],16) and claim['size']>0,(name,'unverified post-ZP alias')
            widths[name]=claim['size'];decls.add(i)
        elif match:
            name=match[1];decls.add(i)
            following=meaningful[position+1][1] if position+1<len(meaningful) else ''
            if re.fullmatch(r'\.word\s+[^,]+(?:,[^,]+)*',following):widths[name]=2*len(following.split(None,1)[1].split(','))
            elif re.fullmatch(r'\.byte\s+[^,]+(?:,[^,]+)*',following):widths[name]=len(following.split(None,1)[1].split(','))
            elif fill:=re.fullmatch(r'\.fill\s+([0-9]+|\$[0-9a-fA-F]+),.*',following):widths[name]=integer(fill[1])
            else:widths[name]=None
    # Match complete tokens only; unrelated prefixes do not alias capture cells.
    canonical={name for name in widths if CANONICAL.fullmatch(name)}
    memory_ops=set('adc and asl bit cmp cpx cpy dec eor inc lda ldx ldy lsr ora rol ror sbc sta stx sty'.split())
    for i,text in meaningful:
        if i in decls:continue
        references={name for name in widths if re.search(r'(?<![A-Za-z_0-9])'+re.escape(name)+r'(?![A-Za-z_0-9])',text,re.I)}
        if not references:continue
        op_and_operand=text.split(None,1);op=op_and_operand[0].lower();operand=op_and_operand[1] if len(op_and_operand)>1 else ''
        direct=re.fullmatch(r'([A-Za-z_][A-Za-z_0-9]*)(?:\s*([+-])\s*([0-9]+|\$[0-9a-fA-F]+))?',operand)
        if direct and op in memory_ops:
            name=next((n for n in widths if n.lower()==direct[1].lower()),None)
            offset=integer(direct[3])*(1 if direct[2]=='+' else -1) if direct[3] else 0
            if name is not None and widths[name] is not None and 0<=offset<widths[name] and (name not in canonical or widths[name]==2):continue
        escapes.append(dict(line=i+1,text=text,symbols=sorted(references)))
    # Source objects retain the ordinary pointer/index validity contract, but
    # explicit direct base+offset accesses may not walk beyond their object into
    # a neighboring capture. Derive these bounds from exact map/VICE extents.
    labels=labels or {}
    source_widths={}
    for section in mapping.get('sections',[]):
        if section['kind']=='code' or section.get('start') is None:continue
        if section['owner']=='compiler' and section['kind']=='scratch':continue
        starts=sorted({labels[name] for name in section['labels'] if name in labels})
        for name in section['labels']:
            if name not in labels:continue
            addr=labels[name];end=next((v for v in starts if v>addr),section['end'])
            if end is not None and end>addr:source_widths[name]=end-addr
    for claim in claims.values():
        if claim.get('kind')=='parameter':source_widths[claim['label']]=claim['size']
    for i,text in meaningful:
        parts=text.split(None,1)
        if len(parts)!=2 or parts[0].lower() not in memory_ops:continue
        direct=re.fullmatch(r'([A-Za-z_][A-Za-z_0-9]*)(?:\s*([+-])\s*([0-9]+|\$[0-9a-fA-F]+))?',parts[1])
        if not direct:continue
        name=next((n for n in source_widths if n.lower()==direct[1].lower()),None)
        if name is None:continue
        offset=integer(direct[3])*(1 if direct[2]=='+' else -1) if direct[3] else 0
        if not 0<=offset<source_widths[name]:escapes.append(dict(line=i+1,text=text,symbols=[name],kind='out_of_source_object_direct_reference'))
    return escapes


def verify_pair(before, after):
    b = parse(str(before)+'.asm');a = parse(str(after)+'.asm')
    assert b[4] == a[4], (before, after, 'symbolic instruction sequence changed')
    bm=json.loads(Path(str(before)+'.zpmap.json').read_text());am=json.loads(Path(str(after)+'.zpmap.json').read_text())
    assert bm.get('zero_page',{}).get('claims',[])==am.get('zero_page',{}).get('claims',[]),(before,'live ZP claims changed')
    labelpath=Path(str(before)+'.labels');labels={m[2]:int(m[1],16) for line in labelpath.read_text().splitlines() if (m:=re.fullmatch(r'al ([0-9a-fA-F]+) \.(.+)',line))} if labelpath.exists() else {}
    escapes=family_escapes(b,bm,labels)
    removed = set(b[2]) - set(a[2]);added = set(a[2]) - set(b[2]);assert not added, (after, 'unexpected added labels', added)
    assert not removed or not escapes,(before,'family cross-base/index/address escape prevents pruning',escapes)
    dropped_lines = set();records = []
    for name in sorted(removed):
        assert CANONICAL.fullmatch(name), (before, 'noncanonical removed object', name)
        assert len(b[2][name]) == 1
        label_line = b[2][name][0]
        assert b[3][label_line] == ('compiler','scratch'), (before, name, 'not compiler scratch')
        following = next(((i,t) for i,t in b[1] if i > label_line), None)
        assert following is not None and following[1] == '.word 0' and b[3][following[0]] == ('compiler','scratch'), (before,name,'not exact2byte word')
        uses = [(i,t) for i,t in b[1] if i != label_line and re.search(r'(?<![A-Za-z_0-9])'+re.escape(name)+r'(?![A-Za-z_0-9])', t, re.I)]
        assert not uses, (before,name,'deleted symbol has nondefinition uses',uses)
        # An adjacent co-located label would be retained text but change storage
        # identity; reject it independently of the production model.
        previous = [t for i,t in b[1] if i < label_line]
        if previous:
            assert not LABEL.fullmatch(previous[-1]), (before,name,'co-located predecessor alias')
        dropped_lines |= {label_line, following[0]}
        records.append(dict(label=name, bytes=2, owner='compiler', kind='scratch', uses=0))
    retained = [text for i,text in b[1] if i not in dropped_lines]
    assert retained == [text for _,text in a[1]], (before,after,'change beyond approved label/word deletions')
    bm=json.loads(Path(str(before)+'.zpmap.json').read_text());am=json.loads(Path(str(after)+'.zpmap.json').read_text())
    data = lambda m:[(s['owner'],s['kind'],s['size'],s['labels']) for s in m['sections'] if s['kind']!='code' and not (s['owner']=='compiler' and s['kind']=='scratch')]
    assert data(bm)==data(am), (before,after,'source/function/other data changed')
    alive=[];unused_retained=[]
    for name, defs in b[2].items():
        if CANONICAL.fullmatch(name) and name not in removed:
            count=sum(len(re.findall(r'(?<![A-Za-z_0-9])'+re.escape(name)+r'(?![A-Za-z_0-9])',t,re.I)) for i,t in b[1] if i not in defs)
            if count:alive.append(dict(label=name, symbolic_uses=count))
            else:unused_retained.append(dict(label=name, symbolic_uses=0))
    asm = Path(str(before)+'.asm').read_text()
    guarded = ('; inline asm' in asm or bool(bm.get('memory_placements')) or 'zeropage_module_reloc_' in asm)
    if guarded:assert before.read_bytes()==after.read_bytes() and not removed, (before,'ASM/module/placement control changed')
    return dict(before=str(before),after=str(after),before_sha256=digest(before),after_sha256=digest(after),before_bytes=before.stat().st_size,after_bytes=after.stat().st_size,
                symbolic_instructions=len(b[4]),symbolic_instruction_sequence_identical=True,significant_text_only_approved_deletions=True,
                removed=records,bytes_pruned=sum(r['bytes'] for r in records),retained_live_slots=alive,retained_unused_slots=unused_retained,guarded_control=guarded,
                source_function_other_data_identical=True,live_zp_claims_identical=True,family_escapes=escapes)


def main():
    p=argparse.ArgumentParser(description=__doc__)
    for name in ('before','after'):p.add_argument('--'+name,type=Path,required=True,action='append',help='artifact directory; repeat to combine corpus and comparison extras')
    p.add_argument('--output',type=Path,required=True)
    args=p.parse_args();bpaths=[x for folder in args.before for x in folder.rglob('*.prg')];apaths=[x for folder in args.after for x in folder.rglob('*.prg')];before={x.name:x for x in bpaths};after={x.name:x for x in apaths}
    assert len(before)==len(bpaths) and len(after)==len(apaths), 'duplicate flattened artifact names'
    assert before.keys()==after.keys(), ('artifact corpus mismatch',before.keys()-after.keys(),after.keys()-before.keys())
    rows=[verify_pair(before[name],after[name]) for name in sorted(before)]
    result=dict(format='zeropage-dead-call-storage-symbolic-proof-v1',status='success',artifacts=len(rows),changed=sum(bool(r['removed']) for r in rows),
                slots_removed=sum(len(r['removed']) for r in rows),bytes_pruned=sum(r['bytes_pruned'] for r in rows),rows=rows,
                scope='Independent significant-assembly and map-data proof. Only canonical compiler:scratch .word0 declarations with zero symbolic uses may disappear. All symbolic instructions/operands and every other meaningful line remain identical; source/function/other data retained. Physical addresses and assembler conditional alignment may relink; native CPU/RAM and corpus timings are proved separately. No blanket RAM/frame normalization.')
    args.output.parent.mkdir(parents=True,exist_ok=True);args.output.write_text(json.dumps(result,indent=2)+'\n');print('PASS',result['artifacts'],'pairs;',result['changed'],'changed;',result['slots_removed'],'slots;',result['bytes_pruned'],'declared bytes pruned')


if __name__=='__main__':main()
