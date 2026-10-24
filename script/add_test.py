#!/usr/bin/env python3
"""Append a test method to a test class, keeping it inside the class body.

Usage: python3 script/add_test.py <test file> <class name> <method source file>
"""
import sys
from pathlib import Path


def add(path, class_name, method):
    text = path.read_text()
    marker = f"if __name__ == '__main__':"
    index = text.find(marker)
    if index < 0:
        raise SystemExit('no main guard found')
    head, tail = text[:index], text[index:]
    # keep the blank lines that separated the class from the guard
    head = head.rstrip('\n') + '\n\n'
    path.write_text(head + method.rstrip('\n') + '\n\n\n' + tail)
    print(f'added to {path.name}::{class_name}')


if __name__ == '__main__':
    target, klass, source = (Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3]))
    add(target, klass, source.read_text())
