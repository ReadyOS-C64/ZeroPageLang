#!/usr/bin/env python3
"""Verify generated fixed-stride helpers against the actual generic NMOS routine."""
import argparse
import ctypes as c
import hashlib,json,re,sys
from pathlib import Path
sys.path.insert(0,'scripts')
from verify_runtime_loop_pages import Regs,bind
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--prg',type=Path,required=True)
parser.add_argument('--library',type=Path,required=True)
parser.add_argument('--output',type=Path,required=True)
args=parser.parse_args()
prg=args.prg;data=prg.read_bytes()
assert len(data)>100
labels={m[2]:int(m[1],16) for line in Path(str(prg)+'.labels').read_text().splitlines() if (m:=re.fullmatch(r'al ([0-9a-fA-F]+) \.(.+)',line))}
factors=sorted(int(n.removeprefix('zeropage_stride_mul_')) for n in labels if n.startswith('zeropage_stride_mul_'))
lib=c.CDLL(str(args.library.resolve()));ptr=c.c_void_p
create=bind(lib,'create',[],ptr);destroy=bind(lib,'destroy',[ptr]);reset=bind(lib,'reset',[ptr]);clear=bind(lib,'clear_memory',[ptr]);load=bind(lib,'load',[ptr,c.c_uint16,c.POINTER(c.c_uint8),c.c_size_t]);read=bind(lib,'read',[ptr,c.c_uint16],c.c_uint8);write=bind(lib,'write',[ptr,c.c_uint16,c.c_uint8]);set_pc=bind(lib,'set_pc',[ptr,c.c_uint16]);set_sp=bind(lib,'set_sp',[ptr,c.c_uint8]);set_a=bind(lib,'set_a',[ptr,c.c_uint8]);set_x=bind(lib,'set_x',[ptr,c.c_uint8]);set_y=bind(lib,'set_y',[ptr,c.c_uint8]);set_p=bind(lib,'set_p',[ptr,c.c_uint8]);get_regs=bind(lib,'regs',[ptr],Regs);run=bind(lib,'run_until_rts',[ptr,c.c_uint8,c.c_uint32],c.c_int)
machines=[create(),create()];payload=(c.c_uint8*(len(data)-2)).from_buffer_copy(data[2:])
for m in machines:
 clear(m);load(m,int.from_bytes(data[:2],'little'),payload,len(payload))
 for addr in range(256):write(m,addr,(addr*17+3)&255)
 for addr in (0xbfff,0xc006,0xc007):write(m,addr,0xa5)
rows={};decimal_cases=0;cases=0

def execute(m,label,value,flags):
 reset(m);set_pc(m,labels[label]);set_sp(m,0xf9);set_a(m,value&255);set_x(m,value>>8);set_y(m,(value^(flags*17))&255);set_p(m,0x20|flags)
 assert run(m,0xf9,10000)==0
 r=get_regs(m)
 return r,(r.a,r.x,r.y,r.p,r.sp),read(m,0xc004)|(read(m,0xc005)<<8)

def check(factor,value,flags):
 global cases,decimal_cases
 a,b=[execute(m,phase+'_'+str(factor),value,flags) for m,phase in zip(machines,('before','after'))]
 assert a[1:]==b[1:],(factor,value,flags,'state/result scratch mismatch',a[1:],b[1:])
 if not flags&8:assert b[0].a|(b[0].x<<8)==(value*factor)&65535,(factor,value,flags,b[1])
 row=rows[factor];row['cases']+=1;row['before_cycles']+=a[0].cycles;row['after_cycles']+=b[0].cycles;row['before_instructions']+=a[0].instructions;row['after_instructions']+=b[0].instructions;row['slower_cases']+=b[0].cycles>a[0].cycles
 cases+=1;decimal_cases+=bool(flags&8)

try:
 for factor in factors:
  kind='power_of_two' if factor&(factor-1)==0 else 'shifted_add';shift=(factor if kind=='power_of_two' else factor-1).bit_length()-1
  expected=(34 if kind=='power_of_two' else 53)+(shift*6 if shift<8 else 11+shift-8)
  starts=sorted(v for k,v in labels.items() if k.startswith('zeropage_stride_mul_') or k=='zeropage_mul16')
  start=labels['zeropage_stride_mul_'+str(factor)];end=next(x for x in starts if x>start)
  assert end-start==expected,(factor,'helper bytes',expected,end-start)
  rows[factor]={'factor':factor,'kind':kind,'helper_bytes':expected,'cases':0,'before_cycles':0,'after_cycles':0,'before_instructions':0,'after_instructions':0,'slower_cases':0}
  for value in range(65536):
   flags=(value>>8)&0xc7
   check(factor,value,flags);check(factor,value,flags|8)
  # Carry/NZ/V/I/D cross product on invalid BCD and overflow boundaries.
  for value in (0,1,9,10,15,99,127,128,153,255,256,257,0x7fff,0x8000,0x80ff,0xff00,0xffff):
   for bits in range(64):
    flags=(bits&15)|((bits&16)<<2)|((bits&32)<<2);check(factor,value,flags)
  for m in machines:
   assert all(read(m,addr)==(addr*17+3)&255 for addr in range(256)),factor
   assert all(read(m,addr)==0xa5 for addr in (0xbfff,0xc006,0xc007)),factor
  print(f'Passed all words in binary/decimal at stride {factor}',flush=True)
finally:
 for m in machines:destroy(m)
result={'format':'zeropage-stride-equivalence-v1','status':'success','cases':cases,'decimal_cases':decimal_cases,'prg_sha256':hashlib.sha256(data).hexdigest(),'factors':list(rows.values()),'checks':['exact A/X/Y/P/SP','all word inputs binary and NMOS decimal','independent binary modulo16 products','complete multiplier result scratch','all flag combinations at binary/BCD/overflow boundaries','zero-page and adjacent scratch canaries','emitted helper lengths vs cost model'],'scope':'Private native probe uses actual stride_selection.zig emitted helpers and actual runtime.zig generic multiply, excluding final outer RTS. Source-language fixtures and full-corpus integration remain separate.'}
args.output.write_text(json.dumps(result,indent=2)+'\n');print('Passed',cases,'paired calls, decimal',decimal_cases,'slower',sum(x['slower_cases'] for x in rows.values()),flush=True)
