#!/usr/bin/env python3
"""
Cross-platform simulation launcher for L1 Cache Controller.
Compiles design and testbench using ModelSim/QuestaSim vlog and executes vsim.
"""

import os
import sys
import subprocess
import shutil

def find_modelsim_bin():
    candidates = [
        r'D:\intelFPGA_lite\20.1\modelsim_ase\win32aloem',
        r'C:\intelFPGA_lite\20.1\modelsim_ase\win32aloem',
        r'C:\intelFPGA\20.1\modelsim_ase\win32aloem',
        r'D:\intelFPGA\20.1\modelsim_ase\win32aloem',
    ]
    for path in candidates:
        vlog_path = os.path.join(path, 'vlog.exe')
        if os.path.isfile(vlog_path):
            return path
    
    vlog_which = shutil.which('vlog') or shutil.which('vlog.exe')
    if vlog_which:
        return os.path.dirname(vlog_which)
    
    return None

def main():
    repo_root = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
    os.chdir(repo_root)
    print(f'=== Running L1 Cache Controller Simulation in {repo_root} ===')

    bin_dir = find_modelsim_bin()
    if not bin_dir:
        print('Error: ModelSim vlog executable not found.')
        sys.exit(1)

    vlog = os.path.join(bin_dir, 'vlog.exe')
    vsim = os.path.join(bin_dir, 'vsim.exe')
    vlib = os.path.join(bin_dir, 'vlib.exe')

    if not os.path.isdir('work'):
        subprocess.run([vlib, 'work'], check=True)

    compile_cmd = [
        vlog, '-work', 'work',
        '+incdir+src',
        'src/l1_cache_controller.v',
        'sim/main_memory_model.v',
        'sim/tb_l1_cache.v'
    ]
    print('[1/2] Compiling Verilog sources...')
    res = subprocess.run(compile_cmd)
    if res.returncode != 0:
        print('Compilation failed.')
        sys.exit(res.returncode)

    sim_cmd = [
        vsim, '-c',
        '-do', 'run -all; quit -f',
        'work.tb_l1_cache'
    ]
    print('[2/2] Executing ModelSim testbench...')
    res = subprocess.run(sim_cmd)
    if res.returncode != 0:
        print('Simulation failed.')
        sys.exit(res.returncode)

    print('\n=== Simulation completed successfully! ===')

if __name__ == '__main__':
    main()
