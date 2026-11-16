#!/usr/bin/env python3
"""Prepare only the owned loopback memory UI fixture; no production URL is accepted."""
from pathlib import Path
import importlib.util,json,datetime,uuid,os
os.umask(0o077)
root=Path('/Users/achilles/mjora/execution/memories-20261117')
record=root/'fixture.json'
spec=importlib.util.spec_from_file_location('fixture',Path(__file__).with_name('fixture.py'))
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
f=json.loads(Path('/Users/achilles/mjora/execution/photos-phase4/legacy-ui-fixture.json').read_text())
assert f['apiURL']=='http://127.0.0.1:33284/api' and f['email']=='legacy-ui@imora-phase4-fixture.invalid'
m.BASE=f['apiURL']
a=m.API();login=a.request('POST','/auth/login',{'email':f['email'],'password':f['password']});a=m.API(token=login['accessToken'])
assert a.request('GET','/users/me')['id']==f['ownerID']
if record.exists():
 data=json.loads(record.read_text());assert data['ownerID']==f['ownerID']
 print('Owned memory fixture already prepared');raise SystemExit
photos=a.request('POST','/search/metadata',{'size':100,'page':1})['assets']['items']
assert len(photos)>=6 and all(x['ownerId']==f['ownerID'] for x in photos)
clip=Path('/Users/achilles/mjora/execution/photos-phase4/services/video-media/sdr-landscape.mp4')
assert clip.is_file() and not clip.is_symlink()
v=a.upload(clip,deviceAssetId='memory-slideshow-'+str(uuid.uuid4()),deviceId='memory-slideshow-fixture')['id']
assetIDs=[photos[0]['id'],photos[1]['id'],v,photos[2]['id']]
ids=[]
for year in [2024,2025]:
 body={'type':'on_this_day','data':{'year':year},'memoryAt':datetime.datetime.now(datetime.timezone.utc).isoformat(),'isSaved':True,'assetIds':assetIDs}
 ids.append(a.request('POST','/memories',body)['id'])
data={'apiURL':f['apiURL'],'ownerID':f['ownerID'],'memoryIDs':ids,'assetIDs':assetIDs,'videoIndex':next(i for i,x in enumerate(a.request('GET','/memories/'+ids[0])['assets']) if x['type']=='VIDEO'),'sharedCover':True}
record.write_text(json.dumps(data,indent=2)+'\n')
print(json.dumps({'memoriesCreated':len(ids),'itemsPerMemory':len(assetIDs),'sharedCover':True,'videoIndex':next(i for i,x in enumerate(a.request('GET','/memories/'+ids[0])['assets']) if x['type']=='VIDEO')}))
