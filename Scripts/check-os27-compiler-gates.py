#!/usr/bin/env python3
"""Fail when OS 27-only availability sites are not behind `#if compiler(>=6.4)`.

The 27 SDKs ship with Swift 6.4 (Xcode 27). CI and SDK consumers can still build with Xcode 26
(Swift 6.2/6.3, 26 SDKs), where 27-only types do not exist, so `@available(… 27 …)` / `#available(… 27 …)`
alone is not enough: the code must also be compiled out with `#if compiler(>=6.4)`. An availability
list is treated as 27-only when every platform version it names is 27 or later (so mixed lists such
as `@available(iOS 18.4, visionOS 2.4, macOS 27.0, *)` for frameworks that exist in the 26 SDKs are
allowed). Doc comments and line comments are ignored.

Usage: Scripts/check-os27-compiler-gates.py [paths...]   (default: Sources Tests Examples)
"""
import re
import subprocess
import sys

AVAILABILITY = re.compile(r"(@available|#available|#unavailable)\s*\(([^)]*)\)")
PLATFORM_VERSION = re.compile(
    r"\b(iOS|iOSApplicationExtension|macOS|macOSApplicationExtension|macCatalyst|tvOS|watchOS|visionOS)\s+(\d+)(?:\.\d+)*"
)


def swift_files(paths):
    output = subprocess.check_output(["git", "ls-files", "--", *[f"{p}/*.swift" for p in paths]])
    return [line for line in output.decode().splitlines() if line]


def is_27_only(arguments):
    versions = [int(major) for _, major in PLATFORM_VERSION.findall(arguments)]
    return bool(versions) and all(major >= 27 for major in versions)


def check(path):
    problems = []
    stack = []
    with open(path, encoding="utf-8", errors="replace") as handle:
        for number, line in enumerate(handle, 1):
            stripped = line.strip()
            if stripped.startswith("#if "):
                stack.append(stripped)
            elif stripped.startswith("#elseif"):
                if stack:
                    stack[-1] = stripped
            elif stripped.startswith("#else"):
                if stack:
                    stack[-1] = "#else"
            elif stripped.startswith("#endif"):
                if stack:
                    stack.pop()
            if stripped.startswith("//"):
                continue
            code = line.split("//", 1)[0]
            for match in AVAILABILITY.finditer(code):
                if not is_27_only(match.group(2)):
                    continue
                if any("compiler(>=6.4)" in condition for condition in stack):
                    continue
                problems.append(f"{path}:{number}: 27-only availability outside '#if compiler(>=6.4)': {stripped[:120]}")
    return problems


def main():
    paths = sys.argv[1:] or ["Sources", "Tests", "Examples"]
    problems = [problem for path in swift_files(paths) for problem in check(path)]
    for problem in problems:
        print(problem)
    if problems:
        print(f"{len(problems)} OS 27 availability site(s) need a '#if compiler(>=6.4)' guard.")
        return 1
    print("OS 27 compiler-gate check passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
