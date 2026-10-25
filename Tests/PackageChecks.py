"""Validate the real dpkg output, not a tree with its architecture renamed."""
import hashlib,io,pathlib,plistlib,subprocess,sys,tarfile
folder=pathlib.Path(sys.argv[1])
for scheme,prefix,architecture in [('rootless','var/jb/','iphoneos-arm64'),('roothide','','iphoneos-arm64e')]:
    directory=folder if scheme=='rootless' else folder/'roothide'
    packages=list(directory.glob('*.deb'));assert len(packages)==1,packages
    package=packages[0]
    control=subprocess.check_output(['dpkg-deb','--ctrl-tarfile',str(package)])
    payload=subprocess.check_output(['dpkg-deb','--fsys-tarfile',str(package)])
    with tarfile.open(fileobj=io.BytesIO(control)) as archive:
        fields=archive.extractfile('./control').read().decode()
        assert 'Architecture: '+architecture+'\n' in fields
        assert 'Package: com.gokuencinar.ultimatecam\n' in fields
        scripts=[archive.extractfile('./'+n).read().decode() for n in ['postinst','prerm']]
        assert all(('/var/jb' in s)==(scheme=='rootless') for s in scripts)
        assert all(s.startswith('#!'+('/var/jb/bin/sh' if scheme=='rootless' else '/bin/sh')) for s in scripts)
        assert all('killall' not in s and 'respring' not in s for s in scripts)
        manifest=archive.extractfile('./md5sums').read().decode()
    with tarfile.open(fileobj=io.BytesIO(payload)) as archive:
        files={n.name.removeprefix('./'):n for n in archive if n.isfile()}
        assert files and all(n.startswith(prefix+'Applications/UltimateCAM.app/') for n in files)
        for line in manifest.splitlines():
            digest,name=line.split('  ',1);assert hashlib.md5(archive.extractfile(files[name]).read()).hexdigest()==digest
        info=plistlib.loads(archive.extractfile(files[prefix+'Applications/UltimateCAM.app/Info.plist']).read())
        assert info['CFBundleIdentifier']=='com.gokuencinar.ultimatecam' and info['NSMicrophoneUsageDescription']
        legal=prefix+'Applications/UltimateCAM.app/Legal/'
        assert b'Apache License' in archive.extractfile(files[legal+'Google-Burst-Denoising.txt']).read()
        assert b'Copyright 2018 Google LLC' in archive.extractfile(files[legal+'THIRD-PARTY-NOTICES.txt']).read()
    expected=(directory/'SHA256SUMS.txt').read_text().split()[0]
    assert hashlib.sha256(package.read_bytes()).hexdigest()==expected
    print('PACKAGE CHECK PASSED:',scheme,architecture)
