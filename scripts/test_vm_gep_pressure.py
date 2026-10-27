#!/usr/bin/env python3
"""Differential machine-code test for optnone GEP metadata pressure.

Uses the matching Linux host LLVM/plugin. Checks constant and dynamic GEPs
without objectsize plus functions that actually require extent tracking.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess

def run(command, env):
    result = subprocess.run(list(map(str, command)), env=env, capture_output=True,
                            text=True, timeout=240)
    if result.returncode or 'skip function' in result.stderr or 'ERROR amice' in result.stderr:
        raise RuntimeError(result.stdout + result.stderr)
    return result.stdout.strip()

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--llvm', type=Path, required=True)
    parser.add_argument('--plugin', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    out = args.output.resolve(); out.mkdir(parents=True, exist_ok=True)
    llvm = args.llvm.resolve(); plugin = args.plugin.resolve()
    env = {k:v for k,v in os.environ.items() if not k.startswith('AMICE_')}
    env.update(LD_LIBRARY_PATH=str(llvm/'lib'), AMICE_VM_EMIT_MARKERS='true',
               AMICE_PANIC_POLICY='abort', RUST_LOG='amice::aotu::vm_virtualize=debug')
    statements = '\n'.join(f'  state[{i}] = x + {i}U; sum ^= state[{i}];' for i in range(80))
    source = out/'gep_pressure.c'
    source.write_text('''#include <stdint.h>
#include <stdio.h>
#define VM __attribute__((noinline,optnone,annotate("+vmp")))
VM uint64_t pressure(uint64_t x) {
  uint64_t state[80], sum = 0;
''' + statements + r'''
  for (unsigned i=0; i<80; ++i) { state[i] ^= x+i; sum += state[i]; }
  return sum;
}
VM uint64_t extent(unsigned n) {
  unsigned char storage[64];
  return __builtin_dynamic_object_size(storage+(n%64),0);
}
VM uint64_t dynamic_extent(unsigned n) {
  unsigned char storage[n+8];
  return __builtin_dynamic_object_size(storage+(n%8),0);
}
int main(void) {
  uint64_t digest=0;
  for(unsigned n=0;n<128;++n) { digest = digest*0x100000001b3ULL + pressure((uint64_t)n*0x9e3779b97f4a7c15ULL);
    digest += extent(n) + dynamic_extent(n); }
  printf("%016llx\n",(unsigned long long)digest);
}
''')
    reports=[]
    for opt in ('-O0','-O2'):
        baseline=out/('baseline'+opt); protected=out/('protected'+opt)
        flags=['-fno-vectorize','-fno-slp-vectorize','-fno-unroll-loops',opt]
        run([llvm/'bin/clang',*flags,source,'-o',baseline],env)
        expected=run([baseline],env)
        ir=out/('protected'+opt+'.ll')
        run([llvm/'bin/clang',*flags,'-fpass-plugin='+str(plugin),
             '-S','-emit-llvm',source,'-o',ir],env)
        text=ir.read_text()
        for name in ('pressure','extent','dynamic_extent'):
            if '@.amice.vm.meta.'+name not in text:
                raise RuntimeError('VM missing for '+name)
        if 'call i64 @llvm.objectsize' in text:
            raise RuntimeError('objectsize escaped virtualization')
        run([llvm/'bin/clang',*flags,'-Xclang','-disable-llvm-passes',ir,'-o',protected],env)
        actual=run([protected],env)
        if actual != expected: raise RuntimeError(f'{opt}: {actual} != {expected}')
        reports.append(dict(optimization=opt,digest=actual,virtualized_functions=3))
        print(json.dumps(reports[-1]),flush=True)
    (out/'report.json').write_text(json.dumps(reports,indent=2)+'\n')

if __name__=='__main__': main()
