#!/usr/bin/env python3
"""Offline environment geometry review; no authority or production AI navigation.
Six-pixel clearance includes the five-pixel native inspector with margin.
Writes authored route annotations only with --write; otherwise verifies them.
"""
from __future__ import annotations
from collections import deque
from pathlib import Path
import argparse, copy, json, math
ROOT=Path(__file__).resolve().parents[1]
GRID=8
CLEARANCE=6
PATH=ROOT/'game/presentation/northline_zone/zone.json'


def occupancy(data: dict) -> tuple[list[bytearray],int,int]:
    width,height=(int(v)//GRID+1 for v in data['size'])
    blocked=[bytearray(width) for _ in range(height)]
    for rx,ry,w,h in data['collision_rects']+data['cover_rects']:
        x0=max(0,math.ceil((rx-CLEARANCE)/GRID));x1=min(width-1,math.floor((rx+w+CLEARANCE)/GRID))
        y0=max(0,math.ceil((ry-CLEARANCE)/GRID));y1=min(height-1,math.floor((ry+h+CLEARANCE)/GRID))
        for y in range(y0,y1+1):blocked[y][x0:x1+1]=b'\1'*(x1-x0+1)
    return blocked,width,height


def nearest(at: list, grid: list[bytearray], bbox: list|None=None) -> tuple[int,int]:
    width,height=len(grid[0]),len(grid)
    x,y=(round(v/GRID) for v in at)
    for radius in range(0,17):
        options=[]
        for ny in range(max(1,y-radius),min(height-1,y+radius+1)):
            for nx in range(max(1,x-radius),min(width-1,x+radius+1)):
                if grid[ny][nx]:continue
                if bbox is not None and not (bbox[0]+10<=nx*GRID<=bbox[0]+bbox[2]-10 and bbox[1]+10<=ny*GRID<=bbox[1]+bbox[3]-10):continue
                options.append(((nx-x)**2+(ny-y)**2,nx,ny))
        if options:
            _,nx,ny=min(options);return nx,ny
    raise ValueError('No clear review anchor near '+repr(at))


def flood(blocked: list[bytearray],start: tuple[int,int]) -> dict:
    width,height=len(blocked[0]),len(blocked)
    if blocked[start[1]][start[0]]:raise ValueError('Blocked start')
    parent={start:None};q=deque([start])
    while q:
        x,y=q.popleft()
        for nx,ny in ((x+1,y),(x,y+1),(x-1,y),(x,y-1)):
            if 0<=nx<width and 0<=ny<height and not blocked[ny][nx] and (nx,ny) not in parent:
                parent[(nx,ny)]=(x,y);q.append((nx,ny))
    return parent


def path_to(parents: dict,goal: tuple[int,int]) -> list[list[int]]:
    if goal not in parents:raise ValueError('Unreachable goal '+repr(goal))
    route=[]
    while goal is not None:
        route.append([goal[0]*GRID,goal[1]*GRID]);goal=parents[goal]
    return route[::-1]


def simplify(points:list[list[int]])->list[list[int]]:
    if len(points)<3:return points
    keep=[points[0]]
    for a,b,c in zip(points,points[1:],points[2:]):
        if (b[0]-a[0],b[1]-a[1])!=(c[0]-b[0],c[1]-b[1]):keep.append(b)
    keep.append(points[-1]);return keep


def route_via(data:dict,grid:list[bytearray],waypoints:list[list[int]])->list:
    full=[]
    for start,end in zip(waypoints,waypoints[1:]):
        path=path_to(flood(grid,nearest(start,grid)),nearest(end,grid))
        full.extend(path if not full else path[1:])
    return simplify(full)


def report(data:dict)->dict:
    grid,_,_=occupancy(data);start=nearest(data['spawn'],grid);seen=flood(grid,start)
    goals=[]
    for kind,entries in [('exit',data['exits']),('district',data['sectors'])]:
        for entry in entries:goals.append((kind,entry['id'],nearest(entry['at'],grid)))
    for b in data['buildings']:
        x,y,w,h=b['rect'];goals.append(('interior',b['id'],nearest([x+w/2,y+h/2],grid,b['rect'])))
    for i,at in enumerate(data['spawn_points']):goals.append(('spawn',str(i),nearest(at,grid)))
    missing=[(kind,id) for kind,id,cell in goals if cell not in seen]
    if missing:raise ValueError('Unreachable interiors/landmarks: '+repr(missing))
    return {'grid':GRID,'clearance':CLEARANCE,'reachable_cells':len(seen),'connected_exits':len(data['exits']),'connected_districts':len(data['sectors']),'connected_interiors':len(data['buildings']),'connected_spawns':len(data['spawn_points']),'goals':[{'kind':kind,'id':id,'at':[cell[0]*GRID,cell[1]*GRID],'path_steps':len(path_to(seen,cell))-1} for kind,id,cell in goals]}


def main()->int:
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--write',action='store_true');args=parser.parse_args()
    data=json.loads(PATH.read_text());result=report(data);grid,_,_=occupancy(data)
    if args.write:
        specs=[('Main road / exposed','c6a260',[[104,824],[848,816],[1728,816],[2624,336]]),('South service rotation','77b8a2',[[104,824],[176,1080],[928,1080],[1520,1376],[1712,1376],[1864,1752]]),('North rail bypass','8fadd0',[[104,824],[160,416],[776,376],[912,216],[1680,216],[2328,140],[2624,336]])]
        data['routes']=[{'name':name,'color':color,'points':route_via(data,grid,via)} for name,color,via in specs]
        data['navigation_validation']=result
        # Independent uncompressed route from entry to each exit for native collision tests.
        parents=flood(grid,nearest(data['spawn'],grid))
        data['native_walk_routes']=[{'id':e['id'],'points':simplify(path_to(parents,nearest(e['at'],grid)))} for e in data['exits']]
        PATH.write_text(json.dumps(data,indent=2)+'\n')
    print('NORTHLINE_TOPOLOGY_RESULT '+json.dumps({k:v for k,v in result.items() if k!='goals'},sort_keys=True))
    return 0
if __name__=='__main__':raise SystemExit(main())
