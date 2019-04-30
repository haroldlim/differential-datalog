#! /usr/bin/env python2.7
"""Run various Souffle Datalog programs tests"""

import os
import subprocess
import sys
import shutil

tests_run = 0
tests_passed = 0

def run_command(command):
    """Runs a command in a shell; returns the stdout; on error prints stderr"""
    print "Running", command
    p = subprocess.Popen(command,
                         stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE)
    stdout, stderr = p.communicate()
    if p.returncode != 0 and stderr is not None:
        sys.stderr.write("{}".format(stderr))
    return p.returncode, "{}".format(stdout)

def compile_example(directory, f):
    """Run the Souffle example in directory 'directory'"""
    print "Testing " + directory
    global tests_run, tests_passed
    tests_run = tests_run + 1
    os.chdir(directory)
    code, _ = run_command(["../../tools/souffle-converter.py", f, "souffle"])
    if code == 0:
        code, _ = run_command(["ddlog", "-i", "souffle.dl", "-L", "../../lib"])
    if code == 0:
        tests_passed = tests_passed + 1
    os.chdir("..")
    return code

def run_examples():
    """Run the hand-created examples; these are all named like 'souffle*'"""
    directories = os.listdir(".")
    for d in directories:
        if os.path.isfile(d):
            continue
        if "souffle" not in d:
            continue
        compile_example(d, "test.dl")

def run_remote_tests():
    url = "https://github.com/souffle-lang/souffle/trunk/tests/evaluation"
    code, dirs = run_command(["svn", "ls", url])
    if code != 0:
        return
    for directory in dirs.split("/\n"):
        if not os.path.isdir(directory):
            code, _ = run_command(["svn", "export", url + "/" + directory])
            if code != 0:
                continue
        code = compile_example(directory, directory + ".dl")
        if code == 0:
            shutil.rmtree(directory)
        if tests_run == 10:
            break

def main():
    run_examples()
#    run_remote_tests()
    print "Ran", tests_run, "out of which", tests_passed, "passed"

if __name__ == "__main__":
    main()