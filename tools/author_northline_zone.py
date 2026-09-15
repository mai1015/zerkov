#!/usr/bin/env python3
"""Regenerate the authored Northline layout. Replaces zone.json; review changes before saving.
Run tools/review_northline_routes.py --write afterwards to revalidate topology.
Runtime loads plain JSON, so individual placements remain directly editable.
"""
from pathlib import Path
import json, random, math
R=Path(__file__).resolve().parents[1]
A=json.loads((R/'assets/world/map_studies/atlas.json').read_text())['assets']
W,H=2688,1792
m=dict(id='northline_zone',title='NORTHLINE EXCLUSION ZONE',size=[W,H],tile_size=16,seed=90715,base='grass',scope='connected_environment_walkthrough_not_live_raid',buildings=[],props=[],decals=[],surfaces=[],roads=[],rails=[],fences=[],lights=[],labels=[],pois=[],routes=[],exits=[],collision_rects=[],cover_rects=[],camera_points=[],spawn=[104,824],sectors=[])
def surface(tile,r,tint):m['surfaces'].append(dict(tile=tile,rect=r,tint=tint))
def road(x,y,w,h,d):
 surface('paving',[x-8,y-8,w+16,h+16],'969c87');surface('road',[x,y,w,h],'b4bdb6');m['roads'].append([x,y,w,h,d])
def rect_overlap(a,b,pad=0):
 return a[0]-pad<b[0]+b[2] and a[0]+a[2]+pad>b[0] and a[1]-pad<b[1]+b[3] and a[1]+a[3]+pad>b[1]
def solid(r):m['collision_rects'].append(r)
def prop(k,x,y,tint='ffffff',flip=False,solid_prop=True,avoid=True):
 w,h=A[k]['footprint'];r=[x-w/2,y-h,w,h]
 if avoid and (any(rect_overlap(r,b,5) for b in m['collision_rects']) or any(rect_overlap(r,b,7) for b in m['cover_rects'])):return False
 if not (16<r[0]<W-32 and 16<r[1]<H-16):return False
 m['props'].append(dict(id='northline.zone.prop.%04d'%len(m['props']),asset=k,foot=[x,y],flip=flip,tint=tint,solid=solid_prop))
 if solid_prop:m['cover_rects'].append(r)
 return True
def lamp(x,y,c='edbc7a',radius=68):
 prop('lamp',x,y,solid_prop=False);m['lights'].append(dict(at=[x,y-23],radius=radius,color=c))
def decal(k,x,y,t='9aa184'):m['decals'].append(dict(asset=k,at=[x,y],tint=t))
def door_segments(x,y,w,h,doors,t=8):
 # Shared authored wall solids; same records drive render, collision and validation.
 out=[]
 for side,length in [('n',w),('s',w),('w',h),('e',h)]:
  gaps=sorted(doors.get(side,[]));last=0
  for center,width in gaps+[[length,0]]:
   end=center-width/2
   if end>last:
    out.append([x+last,y-4,end-last,t] if side=='n' else [x+last,y+h-4,end-last,t] if side=='s' else [x-4,y+last,t,end-last] if side=='w' else [x+w-4,y+last,t,end-last])
   last=center+width/2
 return out
bindex={}
def building(id,name,x,y,w,h,style='metal_wall',floor='concrete_grey',doors=None):
 doors=doors or {'s':[[w/2,48]],'e':[[h/2,48]]}
 walls=door_segments(x,y,w,h,doors)
 b=dict(id=id,name=name,rect=[x,y,w,h],wall=style,floor=floor,doors=doors,walls=walls)
 m['buildings'].append(b);bindex[id]=b
 for r in walls:solid(r)
 return b
def rows(id,items,positions):
 b=bindex[id];x,y,_,_=b['rect']
 for i,(px,py) in enumerate(positions):prop(items[i%len(items)],x+px,y+py,flip=i%5==0)
def crates(id,width,depth,kind='crate_green'):
 b=bindex[id];x,y,w,h=b['rect']
 for col in range(width):
  for row in range(depth):prop(['crate_wood',kind,'case'][ (row+col)%3],x+42+col*60,y+60+row*64)
def sector(id,name,at,desc,loot):
 m['camera_points'].append(dict(id=id,name=name,at=at));m['sectors'].append(dict(id=id,name=name,at=at,description=desc,design_interest=loot))
# Site boundary with four clear gates, not decorative collision-free perimeter.
for r in [[0,0,W,12],[0,H-12,1810,12],[1906,H-12,W-1906,12],[0,0,12,758],[0,886,12,H-886],[W-12,0,12,278],[W-12,394,12,H-394]]:solid(r)
# Broad irregular industrial pads; forest and empty ground remain real traversable land.
for tile,r,c in [('dirt',[80,192,2420,1384],'a3a28a'),('concrete_grey',[144,560,660,420],'a3a994'),('concrete',[864,464,960,596],'a4a690'),('concrete_grey',[1824,416,688,540],'a8aa98'),('paving',[176,1140,1200,512],'999d8c'),('concrete',[1824,1140,688,456],'a2a58f'),('dirt',[1344,1120,400,596],'94977a')]:surface(tile,r,c)
# Transport spine with two north/south links, service detours, and crossing points.
road(16,768,2656,96,'h');road(800,192,80,1472,'v');road(1736,288,80,1376,'v');road(240,1032,2112,80,'h')
road(224,1640,1632,64,'h');road(1760,1568,784,64,'h')
surface('dirt',[80,100,2460,88],'b5ad91');surface('dirt',[104,100,64,664],'aaa28d')
# Drainage cut: impassable embankments except two authored bridges.
surface('dirt',[1560,1120,132,600],'677d76')
for r in [[1592,1120,66,230],[1592,1422,66,194]]:solid(r)
m['water_rects']=[[1592,1120,66,230],[1592,1422,66,194]]
for y in [1350,1616]:surface('metal_floor',[1548,y,156,72],'a6a68f')
# Rail sidings are visually traversable; parked wagons create physical breaks.
m['rails']=[[48,282,2592],[48,332,2592],[928,406,832]]
# District 1 west entry/checkpoint.
building('gatehouse','WEST GATE / SEARCH',192,640,144,112,'factory_wall',doors={'s':[[72,44]],'e':[[56,44]]})
building('security','SECURITY / ARMOURY',448,608,256,144,'metal_wall',doors={'s':[[170,52]],'w':[[72,48]]})
rows('gatehouse',['power_console','locker','case'],[(38,45),(111,51),(36,85)])
rows('security',['locker','locker','crate_green','case','sandbags'],[(33,45),(71,45),(126,52),(204,55),(66,114)])
for x,y,k in [(145,722,'tower'),(396,682,'tower'),(354,746,'sandbags'),(368,902,'barrier'),(275,900,'car_wreck'),(548,895,'jeep'),(646,912,'tyres'),(172,933,'warning')]:prop(k,x,y)
sector('checkpoint','01 / WEST CHECKPOINT',[470,710],'Search booths, stalled convoy, armoured gate. The central road is exposed.','Security cases / entry decision')
# District 2 records admin, separated from main warehouse by road and rail spur.
building('customs','CUSTOMS / RECORDS',264,432,288,128,'factory_wall',doors={'s':[[80,48]],'e':[[66,48]],'n':[[220,40]]})
building('dispatch','DISPATCH ANNEX',596,432,144,128,'brick_wall',doors={'s':[[64,48]],'w':[[64,40]]})
rows('customs',['power_console','cabinet','locker','case'],[(39,43),(87,43),(147,49),(204,53),(230,100),(137,107),(66,99)])
rows('dispatch',['power_console','cabinet','boxes'],[(45,42),(100,43),(52,106)])
for x in [210,600,660]:prop('van',x,384)
sector('customs','02 / CUSTOMS RECORDS',[490,466],'Records rooms and dispatch desk. Three entrances connect the rail path and checkpoint.','Intel pocket / covered passage')
# District 3 rail yard and cargo sidings.
for x in [996,1138,1420,1562,2052,2194]:
 prop('industrial_crate',x,263);prop('industrial_crate',x+44,263)
for x in [1080,1380,1660,2240]:prop('industrial_crate',x,340)
building('signal','SIGNAL CABIN',1112,144,192,80,'brick_wall',doors={'s':[[96,48]],'e':[[40,36]]})
rows('signal',['power_console','cabinet','case'],[(36,43),(78,42),(153,64)])
for x,y,k in [(1360,216,'truck'),(1470,214,'crate_broken'),(1680,216,'tower'),(950,384,'barrel_rust'),(2300,292,'jeep')]:prop(k,x,y)
sector('rail','03 / NORTH RAIL SIDINGS',[1352,288],'Three sidings and cargo gaps. A long sightline competes with the outer treeline.','Rail gate / long exposed approach')
# District 4 core freight complex. Multiple entrances with cover islands, not a sealed hall.
building('freight','FREIGHT 04 / BONDED CARGO',984,536,512,216,'metal_wall',doors={'s':[[128,64],[398,64]],'e':[[112,56]],'w':[[112,56]],'n':[[268,64]]})
building('inspection','INSPECTION / SEALED GOODS',1536,568,144,184,'factory_wall',doors={'s':[[72,48]],'w':[[106,44]],'e':[[50,44]]})
for x in [1024,1080,1204,1260,1384,1440]:
 for y in [600,658]:prop('crate_green' if x%3 else 'crate_wood',x,y)
for x,y,k in [(1040,710,'industrial_crate'),(1280,710,'conveyor'),(1430,709,'case'),(1190,689,'crate_broken')]:prop(k,x,y)
rows('inspection',['shelf','case','cabinet','crate_green','boxes'],[(42,48),(101,56),(110,121),(44,146),(96,156)])
# Dense, irregular cargo islands still leave four independent walk-through entrances.
for xx,yy in [(1125,580),(1160,580),(1335,580),(1370,580),(1170,640),(1205,640),(1300,688),(1335,688),(1460,730),(1009,689),(1010,560),(1440,560)]:
 prop('industrial_crate' if xx%2 else 'crate_wood',xx,yy)
for xx,yy in [(1075,720),(1355,720),(1470,615),(1242,585)]:prop('barrel_olive',xx,yy)
# Two rear receiving sheds and a narrow covered service route.
building('receiving','RECEIVING 02',940,904,264,100,'metal_wall',doors={'s':[[110,64]],'e':[[50,40]],'n':[[146,52]]})
building('cold','COLD STORAGE',1264,904,368,100,'metal_wall',doors={'s':[[184,56]],'w':[[50,40]],'n':[[110,52]]})
rows('receiving',['conveyor','crate_wood','case'],[(55,44),(133,42),(216,71)])
rows('cold',['freezer','freezer','crate_green','barrel_olive','shelf_tins'],[(33,49),(91,49),(156,43),(237,46),(305,71)])
for x,y,k in [(1020,863,'truck'),(1216,861,'van'),(1496,881,'industrial_crate'),(1654,912,'barrel_rust'),(913,889,'sandbags')]:prop(k,x,y)
sector('freight','04 / FREIGHT COMPLEX',[1288,638],'Through-warehouse circulation, independent inspection bay, two receiving sheds.','Sealed freight / central contested hub')
# District 5 eastern fuel and power separated by fenced compounds.
building('power','SUBSTATION / SWITCHGEAR',2000,456,344,176,'factory_wall',doors={'s':[[100,52],[270,44]],'w':[[96,48]],'e':[[88,48]]})
rows('power',['power_console','generator','machine','pump'],[(40,48),(97,65),(180,73),(283,69),(90,143),(211,139),(279,140)])
building('fuel_office','FUEL CONTROL',2376,512,152,120,'brick_wall',doors={'s':[[76,48]],'w':[[55,44]]})
rows('fuel_office',['power_console','locker','case'],[(36,44),(98,44),(38,92)])
for xx in range(1904,2480,64):
 for yy in [686,738]:
  if (xx//64+yy)%3:prop('barrel_red' if xx%128 else 'barrel_olive',xx,yy)
for x,y,k in [(1934,528,'tank'),(1938,585,'tank'),(2440,904,'gas_pump'),(2490,904,'gas_pump'),(2212,910,'van'),(2320,926,'car_wreck')]:prop(k,x,y)
sector('power','05 / FUEL + SUBSTATION',[2250,556],'Tank pockets, switchgear and control room. Barrel aisles break up the industrial apron.','Fuel / tools / electrical parts')
# District 6 residential block, a very different pace from freight.
for id,name,x,y,w,h in [('quarters','WORKERS QUARTERS A',224,1200,256,176),('quarters_b','WORKERS QUARTERS B',544,1200,208,176),('canteen','OLD CANTEEN',248,1432,288,152),('store','RATION STORE',608,1440,144,144)]:
 building(id,name,x,y,w,h,'brick_wall','paving',{'s':[[w/2,48]],'e':[[h/2,44]],'n':[[w*.25,40]]})
rows('quarters',['bed_green','cabinet','bed_blue','shelf'],[(38,66),(96,51),(167,66),(225,49),(45,133),(168,139)])
rows('quarters_b',['bed_blue','locker','boxes','bed_green'],[(41,62),(110,55),(167,100),(72,136)])
rows('canteen',['shelf_tins','shelf','bench','freezer','checkout'],[(42,48),(127,48),(70,108),(212,59),(209,128)])
rows('store',['shelf','boxes','cart'],[(36,44),(105,49),(39,117)])
for x,y,k in [(414,1415,'bus'),(570,1320,'trash'),(559,1510,'car_blue'),(154,1500,'tree_dead'),(150,1280,'fallen_log')]:prop(k,x,y)
sector('quarters','06 / WORKERS QUARTERS',[474,1320],'Two dormitories, a ration shop and a canteen. Courtyards and alleys connect the southern bypass.','Residential search / food supplies')
# District 7 evacuation clinic and triage.
building('clinic','EVACUATION CLINIC',992,1200,352,216,'brick_wall','hospital_floor',{'s':[[176,56]],'e':[[108,52]],'w':[[108,52]],'n':[[268,48]]})
rows('clinic',['bed_blue','medical_screen','bed_green','oxygen','cabinet'],[(41,77),(86,67),(135,77),(184,66),(264,62),(313,62),(44,151),(87,149),(137,151),(211,159),(295,173)])
prop('medical_table',1160,1257);prop('med_tools',1207,1257)
building('triage','TRIAGE ANNEX',1040,1480,224,104,'factory_wall','hospital_floor',{'s':[[112,52]],'e':[[52,44]],'n':[[44,40]]})
rows('triage',['medical_table','wheelchair','cabinet'],[(45,48),(134,75),(189,47)])
for x,y,k in [(920,1453,'tent'),(961,1533,'tent'),(1366,1480,'van'),(919,1210,'van'),(1390,1380,'oxygen')]:prop(k,x,y)
sector('clinic','07 / EVACUATION CLINIC',[1140,1300],'Open triage yard and two clinic wings. Multiple doorways prevent a single-entry dead end.','Medical pocket / southern rotation')
# District 8 motor pool and service.
building('repair','MOTOR POOL / REPAIR',1896,1200,416,232,'metal_wall',doors={'s':[[96,72],[305,72]],'w':[[116,56]],'e':[[116,56]],'n':[[208,64]]})
rows('repair',['machine','lathe','power_console','pump','generator'],[(44,68),(114,67),(189,52),(292,69),(365,69),(70,181),(252,188),(342,177)])
for x,y,k in [(2448,1290,'tank'),(2448,1360,'jeep'),(2448,1440,'truck'),(1940,1500,'car_blue'),(2040,1500,'car_wreck'),(2200,1500,'van'),(2260,1510,'tyres'),(2540,1510,'barrel_rust')]:prop(k,x,y)
sector('motor','08 / MOTOR POOL',[2236,1300],'Repair bays, stalled vehicles and a parts yard. Wide garage entries connect both flanks.','Tools / vehicle cover / long east flank')
# District 9 sump, bridge and service tunnels.
building('pumphouse','DRAINAGE / PUMP HOUSE',1384,1496,156,120,'factory_wall',doors={'s':[[78,48]],'e':[[65,48]],'n':[[78,40]]})
rows('pumphouse',['pump','power_console','barrel_olive'],[(39,57),(113,51),(43,91)])
for x,y,k in [(1735,1485,'generator'),(1734,1542,'pump'),(1760,1720,'stairwell'),(1900,1720,'stairwell'),(1500,1680,'warning'),(1670,1720,'barrel_rust')]:prop(k,x,y)
sector('drain','09 / DRAINAGE BYPASS',[1578,1558],'Two bridges over the drainage trench, a pump house and a service-exit approach.','Alternative crossing / drainage exit')
# Explicit authored internal dividing fences: disconnected runs leave multiple gaps.
for x,y,length in [(168,1014,408),(642,1014,128),(940,460,516),(1536,460,144),(1872,984,376),(2340,984,188),(1904,1152,304),(2360,1152,176),(212,1725,450),(968,1725,380)]:
 m['fences'].append([x,y,length]);solid([x,y-5,length,8])
# Hazard strips, pavement labels and parking bays authored in world units.
m['labels']=[dict(text='NORTHLINE // FREIGHT CONTROL',at=[1170,844]),dict(text='STOP / INSPECTION',at=[186,864]),dict(text='NO IDLING',at=[1930,948]),dict(text='EVACUATION',at=[1070,1461]),dict(text='DRAINAGE 02',at=[1440,1660])]
m['parking']=[[1910,1470,384,80],[250,927,420,64],[1840,650,100,110]]
# Lighting localized to landmarks, not a costly light on every prop.
for x,y in [(180,758),(714,748),(570,550),(967,748),(1510,748),(1698,737),(1865,750),(2350,651),(2535,754),(785,1145),(985,1190),(1350,1435),(1272,1598),(1900,1460),(2320,1432),(1558,1605),(1720,1605),(1780,267)]:lamp(x,y)
for x,y in [(1045,1250),(1270,1330),(1093,1519)]:m['lights'].append(dict(at=[x,y],radius=66,color='a5d4bd'))
# Specific clutter islands: intentionally kept off the principal road centerline.
rng=random.Random(m['seed'])
for cx,cy in [(630,930),(903,551),(1660,513),(1432,412),(2110,1022),(2350,1510),(906,1590),(1404,1166),(768,320),(1880,390),(690,1410),(178,1120),(1368,960)]:
 for i in range(10):
  x=cx+rng.randrange(-70,71,8);y=cy+rng.randrange(-28,29,8)
  prop(rng.choice(['crate_broken','barrel_rust','boxes','tyres','industrial_crate','trash']),x,y,tint='b4b09a')
# Woodland perimeter and pockets. Never change building structure or gate clearances.
for y in range(64,H-24,46):
 for x in range(46,W-24,50):
  edge=x<120 or x>2558 or y<95 or (y>1730 and x<1560)
  pocket= (x<740 and 190<y<265) or (1840<x<2520 and 150<y<230) or (84<x<215 and 1140<y<1640)
  if (edge or pocket) and rng.random()<0.85:
   xx=x+rng.randint(-16,16); yy=y+rng.randint(-10,10)
   if 745<yy<900 and xx<178 or 264<yy<418 and xx>2510:continue
   prop(rng.choice(['tree_dead','tree_dead','stump','fallen_log']),xx,yy,'949982')
   decal('fern',xx+7,yy-8,'7f906d')
# Thousands of natural wear marks, all source sprites, with explicit placements in JSON.
for _ in range(2100):
 x=rng.randrange(18,W-30);y=rng.randrange(18,H-35)
 if any(b['rect'][0]-8<x<b['rect'][0]+b['rect'][2]+8 and b['rect'][1]-30<y<b['rect'][1]+b['rect'][3]+8 for b in m['buildings']):continue
 k=rng.choices(['weeds','shrub','rubble_small','puddle'],[55,10,23,12])[0]
 # Avoid dense green growth down the road's maintained centre.
 if any(rx<x<rx+rw and ry<y<ry+rh for rx,ry,rw,rh,_d in m['roads']) and rng.random()<.7:continue
 decal(k,x,y,rng.choice(['858f74','909c81','9a9d89','7f8b79']))
# Edge vegetation along every wall helps unify the cutaway assets.
for b in m['buildings']:
 x,y,w,h=b['rect']
 for px in range(x,x+w,32):decal('weeds',px,y+h+7,'7c8f66')
# Four design exits and multiple entry locations, all well inside the boundary.
m['exits']=[dict(id='west',name='WEST SERVICE',at=[56,824]),dict(id='rail',name='RAIL GATE',at=[2624,336]),dict(id='drain',name='DRAINAGE 02',at=[1864,1752]),dict(id='forest',name='NORTH TREELINE',at=[2328,140])]
m['spawn_points']=[[104,824],[760,1544],[2376,1672],[2312,176]]
m['pois']=[dict(id=s['id'],name=s['name'],at=s['at'],kind=s['design_interest']) for s in m['sectors']]
m['comparison']={'previous_size':[672,448],'new_size':[W,H],'area_multiplier':16,'art_scale_changed':False}
m['navigation_review']={'grid':8,'clearance':6,'method':'four-neighbour occupancy grid with rectangle footprint clearance; native pawn confirmation is separate','not_canonical_raid_navigation':True}
# Record authoring data first; separate review solver emits checked routes later.
(R/'game/presentation/northline_zone/zone.json').write_text(json.dumps(m,indent=2)+'\n')
print('AUTHORED',len(m['buildings']),'buildings',len(m['props']),'props',len(m['decals']),'decals',len(m['collision_rects']),'walls')
