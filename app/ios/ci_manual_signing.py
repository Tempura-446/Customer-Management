#!/usr/bin/env python3
"""CI only: switch the app target's Release and Profile builds to manual signing.

The project stays on automatic signing for people building on their own Mac. On the
GitHub runner there is no Apple account signed in, so before `flutter build ipa` the
release job points the Runner target (only that target: plugins and the test target
are left alone) at the distribution certificate and App Store profile from secrets.

Usage: ci_manual_signing.py path/to/project.pbxproj TEAM_ID "Profile name" [bundle id]
"""
import re
import sys


def patch(text, team, profile, bundle='com.cabinetcrm.cabinetCrm'):
    settings = {
        'CODE_SIGN_STYLE': 'Manual',
        'DEVELOPMENT_TEAM': team,
        'PROVISIONING_PROFILE_SPECIFIER': '"%s"' % profile.replace('"', '\\"'),
        'CODE_SIGN_IDENTITY': '"Apple Distribution"',
        '"CODE_SIGN_IDENTITY[sdk=iphoneos*]"': '"Apple Distribution"',
    }
    block_re = re.compile(
        r'(\t\t[0-9A-F]{24} /\* (Release|Profile) \*/ = \{\n\t\t\tisa = XCBuildConfiguration;\n'
        r'(?:.*\n)*?\t\t\tbuildSettings = \{\n)((?:.*\n)*?)(\t\t\t\};\n\t\t\tname = \2;\n\t\t\};)')
    changed = 0

    def fix(m):
        nonlocal changed
        body = m.group(3)
        if not re.search(r'^\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = %s;$' % re.escape(bundle), body, re.M):
            return m.group(0)  # another target (tests) or the project-level settings
        for key, value in settings.items():
            line = '\t\t\t\t%s = %s;\n' % (key, value)
            pattern = re.compile(r'^\t\t\t\t%s = .*;\n' % re.escape(key), re.M)
            body = pattern.sub(line, body) if pattern.search(body) else line + body
        changed += 1
        return m.group(1) + body + m.group(4)

    out = block_re.sub(fix, text)
    if changed != 2:
        raise SystemExit('expected the Release and Profile configurations of %s, patched %d' % (bundle, changed))
    return out


if __name__ == '__main__':
    path, team, profile = sys.argv[1:4]
    bundle = sys.argv[4] if len(sys.argv) > 4 else 'com.cabinetcrm.cabinetCrm'
    with open(path) as f:
        text = f.read()
    with open(path, 'w') as f:
        f.write(patch(text, team, profile, bundle))
    print('Manual signing set for %s (Release, Profile) with profile "%s"' % (bundle, profile))
