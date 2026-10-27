#!/usr/bin/env python3
"""Compare real feedback-VM machine code against native reference executables.

Use the matching Android host LLVM and plugin, optionally an NDK bundle and
ADB serial. Does not modify the installed bundle or device modules.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SOURCE = r'''
#include <stdint.h>
#include <stdio.h>
#define VM __attribute__((noinline, annotate("+vmp")))
VM uint64_t mix(uint64_t x, unsigned n) {
    uint64_t y = x ^ UINT64_C(0xfedcba9876543210);
    for (unsigned i=0; i<n; ++i) {
        if ((y ^ i) & 1) y = (y << 7) ^ (y >> 13) ^ x;
        else y = y * UINT64_C(0xd6e8feb86659fd93) + i;
    }
    return y;
}
VM uint64_t nested(uint64_t x) { return mix(x, x & 15) ^ mix(~x, 7); }
VM uint64_t memory(uint64_t *p, unsigned n) {
    uint64_t y=0;
    for(unsigned i=0;i<n;++i) { y ^= p[i] + i; p[i] ^= y; }
    return y;
}
VM uint64_t recursive(uint64_t x, unsigned n) {
    if (!n) return x;
    return recursive(x ^ (x >> 3) ^ n, n-1) + x;
}
int main(void) {
    uint64_t digest=0x12345678, cases=0;
    for(unsigned i=0;i<256;++i) {
        uint64_t x=UINT64_C(0x9e3779b97f4a7c15)*i;
        uint64_t p[4]={x,~x,x<<1,x>>1};
        digest ^= mix(x,i&31); ++cases;
        digest += nested(x); ++cases;
        digest ^= memory(p,i%5); ++cases;
        digest += recursive(x,i%9); ++cases;
        for(unsigned j=0;j<4;++j) { digest ^= p[j]; ++cases; }
    }
    printf("%llu %016llx\n",(unsigned long long)cases,(unsigned long long)digest);
    return 0;
}
'''

def run(command, *, env=None, timeout=300):
    result = subprocess.run(list(map(str, command)), env=env, text=True,
                            capture_output=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(f'{command}: exit {result.returncode}\n{result.stdout}\n{result.stderr}')
    if 'skip function' in result.stderr or 'ERROR amice' in result.stderr:
        raise RuntimeError(result.stderr)
    return result.stdout.strip()

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--llvm', type=Path, required=True)
    parser.add_argument('--plugin', type=Path, required=True)
    parser.add_argument('--bundle', type=Path)
    parser.add_argument('--adb', default='adb')
    parser.add_argument('--serial')
    parser.add_argument('--output', type=Path, default=ROOT/'target/feedback-runtime')
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    source = out/'feedback.c'
    source.write_text(SOURCE)
    env = {k:v for k,v in os.environ.items() if not k.startswith('AMICE_')}
    env.update(AMICE_PANIC_POLICY='abort', RUST_LOG='amice::aotu::vm_virtualize=debug')
    env['LD_LIBRARY_PATH'] = str(args.llvm/'lib')+':'+env.get('LD_LIBRARY_PATH','')
    compilers = [('host',args.llvm/'bin/clang',[])]
    if args.bundle:
        clang = args.bundle/'android-ndk-r30/toolchains/llvm/prebuilt/linux-x86_64/bin/clang'
        compilers.append(('arm64',clang,['--target=aarch64-linux-android27']))
    reports=[]
    for target,compiler,flags in compilers:
        # Scalar VM fixture: vectorized poison lanes are outside this test's
        # contract and are correctly rejected by the existing translator.
        flags = [*flags, '-fno-vectorize', '-fno-slp-vectorize', '-fno-unroll-loops']
        def execute(binary):
            if target=='host': return run([binary], env=env)
            if not args.serial: return None
            remote='/data/local/tmp/amice-feedback-'+binary.name
            run([args.adb,'-s',args.serial,'push',binary,remote])
            try:
                return run([args.adb,'-s',args.serial,'shell','chmod','700',remote]) or run([args.adb,'-s',args.serial,'shell',remote])
            finally:
                run([args.adb,'-s',args.serial,'shell','rm',remote])
        baseline=out/(target+'-baseline')
        run([compiler,*flags,'-O2',source,'-o',baseline],env=env)
        expected=execute(baseline)
        for entry in ('call','inline'):
            for scope in ('module','func'):
                for opt in ('-O0','-O2'):
                    name=f'{target}-{entry}-{scope}-{opt[1:]}'
                    profile=out/('profile-'+entry+'-'+scope)
                    shutil.copytree(ROOT/'crates/amice-vm/profiles/amice-simple-vmp',profile,dirs_exist_ok=True)
                    decoder=profile/'decoder.vm'
                    decoder.write_text(decoder.read_text().replace('  step varint_decode','  step record_feedback key=function_key\n  step varint_decode'))
                    runtime=profile/'runtime.vm'
                    runtime.write_text(runtime.read_text().replace('runtime.entry = call',f'runtime.entry = {entry}').replace('runtime.scope = module',f'runtime.scope = {scope}'))
                    case_env=dict(env,AMICE_VM_PROFILE_PATH=str(profile),AMICE_VM_EMIT_MARKERS='true')
                    ir=out/(name+'.ll')
                    run([compiler,*flags,opt,'-fno-discard-value-names','-fpass-plugin='+str(args.plugin.resolve()),'-S','-emit-llvm',source,'-o',ir],env=case_env)
                    text=ir.read_text()
                    if 'feedback.next' not in text or text.count('@.amice.vm.meta.')<4:
                        raise RuntimeError(name+': protected VM/feedback missing')
                    binary=out/name
                    # Match the real late-pass pipeline: avoid running the
                    # full optimization pipeline again over the emitted VM.
                    run([compiler,*flags,opt,'-Xclang','-disable-llvm-passes',ir,'-o',binary],env=env)
                    actual=execute(binary)
                    if expected is not None and actual!=expected:
                        raise RuntimeError(f'{name}: {actual} != {expected}')
                    report=dict(case=name,output=actual,runtime_verified=expected is not None,sha256=hashlib.sha256(binary.read_bytes()).hexdigest())
                    reports.append(report)
                    print(json.dumps(report),flush=True)
    (out/'report.json').write_text(json.dumps(reports,indent=2)+'\n')

if __name__=='__main__': main()
