#!/usr/bin/env python3
"""Live disposable-item test. Needs KEYS_SIGNING_IDENTITY; never touches vault items."""
from pathlib import Path
import os
import re
import shutil
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parent.parent
SOURCE = r'''
#include <Security/Security.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <string.h>
#ifndef VERSION
#define VERSION 1
#endif
int main(int argc, char **argv) {
 if(argc != 4 || strncmp(argv[2], "keysreallysafe.upgrade-test.", 28)) return 2;
 SecKeychainSetUserInteractionAllowed(false);
 CFStringRef service=CFStringCreateWithCString(NULL,argv[2],kCFStringEncodingUTF8);
 CFMutableDictionaryRef q=CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
 CFDictionarySetValue(q,kSecClass,kSecClassGenericPassword);
 CFDictionarySetValue(q,kSecAttrService,service);
 CFDictionarySetValue(q,kSecAttrAccount,CFSTR("disposable"));
 SecKeychainRef keychain=NULL;
 if(SecKeychainOpen(argv[3],&keychain)) return 2;
 CFDictionarySetValue(q,kSecUseKeychain,keychain);
 const void *keychains[]={keychain};
 CFArrayRef search=CFArrayCreate(NULL,keychains,1,&kCFTypeArrayCallBacks);
 if(strcmp(argv[1],"add")) CFDictionarySetValue(q,kSecMatchSearchList,search);
 OSStatus s;
 if(!strcmp(argv[1],"add")) {
  const unsigned char fixture[]={1,2,3,4};
  CFDataRef data=CFDataCreate(NULL,fixture,sizeof(fixture));
  CFDictionarySetValue(q,kSecValueData,data);
  s=SecItemAdd(q,NULL); CFRelease(data);
 } else if(!strcmp(argv[1],"read")) {
  CFDictionarySetValue(q,kSecReturnData,kCFBooleanTrue);
  CFTypeRef data=NULL; s=SecItemCopyMatching(q,&data);
  if(data) CFRelease(data); // Never print the value.
 } else if(!strcmp(argv[1],"delete")) s=SecItemDelete(q);
 else return 2;
 printf("version=%d operation=%s status=%d\n",VERSION,argv[1],(int)s);
 return s ? 1:0;
}
'''


def run(args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


if __name__ == '__main__':
    if not os.environ.get('KEYS_SIGNING_IDENTITY') and not (Path.home()/'.config/keysreallysafe/signing-identity').exists():
        raise SystemExit('Set up an Apple signing identity before running the live upgrade test.')
    service = 'keysreallysafe.upgrade-test.'+str(uuid.uuid4())
    with tempfile.TemporaryDirectory(prefix='keys-upgrade-test-') as temp:
        root = Path(temp)
        source = root/'probe.c'
        source.write_text(SOURCE)
        first, second, stranger, live = [root/p for p in ('v1','v2','stranger','keys')]
        for version, path in ((1,first),(2,second),(3,stranger)):
            run(['/usr/bin/clang','-Wno-deprecated-declarations',f'-DVERSION={version}',source,'-framework','Security','-framework','CoreFoundation','-o',path])
            if version != 3:
                run(['python3',ROOT/'scripts/sign-local.py',path])
            else:
                run(['/usr/bin/codesign','--force','--sign','-','--identifier','keysreallysafe',path])
        assert first.read_bytes() != second.read_bytes(), 'Test requires two genuinely different builds'
        keychain=root/'disposable.keychain-db'
        run(['/usr/bin/security','create-keychain','-p','disposable-test-only',keychain])
        try:
            shutil.copy2(first,live)
            run([live,'add',service,keychain])
            run([live,'read',service,keychain])
            staged=root/'replacement'
            shutil.copy2(second,staged)
            os.replace(staged,live)
            run([live,'read',service,keychain])
            denied=subprocess.run([str(stranger),'read',service,str(keychain)], capture_output=True, text=True)
            print(denied.stdout, end='')
            match = re.fullmatch(r'version=3 operation=read status=(-?\d+)\n', denied.stdout)
            if denied.returncode != 1 or not match or int(match[1]) not in (-25308, -25293):
                raise SystemExit('FAIL: expected Keychain authorization denial from unrelated signer; got '+repr((denied.returncode, denied.stdout, denied.stderr)))
        finally:
            run(['/usr/bin/security','delete-keychain',keychain])
        print('PASS: changed signed build reads without interaction; unrelated signer rejected; disposable keychain removed.')
