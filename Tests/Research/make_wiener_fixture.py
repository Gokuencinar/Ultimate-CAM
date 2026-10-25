"""Generate an independent NumPy oracle from Google's pinned research functions.

No training, model download or camera images. Pass a checkout of
https://github.com/google/burst-denoising as the only argument.
"""
import hashlib,json,pathlib,subprocess,sys
import numpy as np

revision='7ff07e009568778ff337c259e192d1d81aedbea6'
checkout=pathlib.Path(sys.argv[1])
assert subprocess.check_output(['git','-C',str(checkout),'rev-parse','HEAD'],text=True).strip()==revision
source=subprocess.check_output(['git','-C',str(checkout),'show',revision+':py_image.py']).decode('utf-8')
# Reviewed numerical functions only. Do not import the upstream Python 2 file,
# its TensorFlow training entrypoints or arbitrary code outside these functions.
selected=source[source.index('def rcwindow('):source.index('def hdrplus_tiled(')]
namespace={'np':np};exec(compile(selected,'Google-pinned-numerical-reference','exec'),namespace)
rng=np.random.default_rng(20261025)
y,x=np.mgrid[:32,:32]
base=0.2+0.4*x/31+0.1*np.sin(y*0.4)
checker=np.where((x+y)%2,0.75,0.25)
specifications=[
    ('identical',[base.copy() for _ in range(4)],0.02,1),
    ('static_noise',[base+rng.normal(0,0.025,(32,32)) for _ in range(8)],0.025,1),
    ('moving_fine_detail',[checker]+[1-checker for _ in range(3)],0.02,1),
    ('exposure_change',[base]+[base+0.2 for _ in range(3)],0.02,1),
    ('low_acceptance',[base+rng.normal(0,0.04,(32,32)) for _ in range(4)],0.04,0.25),
]
cases=[]
for name,frames,sigma,strength in specifications:
    stacked=np.stack(frames,axis=-1)
    expected=namespace['hdrplus_merge'](stacked,10**2.5*strength,sigma,spatial=False)[1]
    assert np.isfinite(expected).all()
    cases.append(dict(name=name,sigma=sigma,strength=strength,frames=[f.reshape(-1).tolist() for f in frames],expected=expected.reshape(-1).tolist()))
document=dict(upstream_revision=revision,upstream_file_sha256=hashlib.sha256(source.encode()).hexdigest(),side=32,cases=cases)
destination=pathlib.Path(__file__).resolve().parents[1]/'Fixtures/GoogleWiener32.json'
destination.parent.mkdir(exist_ok=True)
destination.write_text(json.dumps(document,separators=(',',':')),encoding='utf-8')
print('Generated pinned NumPy FFT oracle:',len(cases),'cases,',destination.stat().st_size,'bytes')
