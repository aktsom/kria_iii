-- ============================================================
-- kria iii  v1.1.0
-- ============================================================
-- 4-track MIDI step sequencer for monome grid + iii
-- single file, lua 5.3, ~31-32 KB heap ceiling + ~32 KB source buffer
--
-- NOTE: this commented file is a READING REFERENCE ONLY.
-- do NOT upload this to iii - the extra comments push the
-- source past iii's script buffer limit and upload will fail.
-- upload kria_iii.lua instead (same code, no comments).
--
-- identifiers are kept short on purpose (heap budget).
-- the file is organised in labelled sections; use them
-- to jump around. core state and function purposes are
-- summarised below.
--
-- ------------------------------------------------------------
-- GRID LAYOUT  (16x8, top-left = 1,1)
-- ------------------------------------------------------------
-- y=8  nav row (always on unless cfh/tmh held)
--      x=1-4   track select / mute (when mlh held)
--      x=6     trigger page (vm=1)   tap again = ratchet (vm=11)
--      x=7     note page    (vm=2)   tap again = alt-note (vm=12)
--      x=8     octave page  (vm=3)
--      x=9     duration     (vm=4)
--      x=11    LOOP overlay hold (mlh)
--      x=12    TIME-DIV overlay hold (mth)
--      x=13    PROB overlay hold (mph)
--      x=15    scale page (vm=6)
--      x=16    pattern page (vm=7) / blinks on transport
--
-- y=7 on trigger page (vm=1):
--      x=6    TIME page hold (tmh) - tempo / ext mult
--      x=7    CONFIG page hold (cfh) - note-sync / loop-sync
--      x=15   play / stop
--      x=16   reset playheads to loop start
-- y=7 on pattern page (vm=7):
--      x=1    LOAD psets from disk (hold 2s)
--      x=2    pattern clear mode toggle
--      x=3    SAVE all psets to disk (hold 2s)
--      x=15   play / stop       x=16   reset
--
-- ------------------------------------------------------------
-- PAGES (vm)
-- ------------------------------------------------------------
--  1 trigger    2 note      3 octave     4 duration
--  6 scale      7 pattern
-- 11 ratchet   12 alt-note
--
-- HOLD MODIFIERS (override active page while held)
--   mlh  loop start/end per track
--   mth  clock division per track
--   mph  trigger probability per step
--   cfh  note-sync / loop-sync config
--   tmh  tempo fine adjust / ext clock multiplier
--
-- ------------------------------------------------------------
-- PER-TRACK STATE (arrays [track][step] unless noted)
-- ------------------------------------------------------------
--   tr    trigger bool          no    note index 1-7
--   oc    octave 2-7            du    duration 0-5
--   prb   trig probability 1-4  rdv   ratchet count 1-5
--   rsl   ratchet slot bitmask  an2   alt-note offset -1..6
--   ph    trigger playhead      aph   alt-note playhead
--   nph   note-quantise playhead
--   ls/le loop start/end        als/ale  alt-note loop
--   dv2   trigger clock div     adv2  alt-note clock div
--   sdir  direction 1-5 (fwd/rev/ping/drunk/rand)
--   mute  per track             tclk  note-quantise mode
--   TCH   midi channel          an    currently playing note
--   go2   global octave index
--
-- ------------------------------------------------------------
-- SCALE SYSTEM
-- ------------------------------------------------------------
--   sr         root midi note (48 = C3)
--   si[1..7]   intervals (semitones)
--   cs[1..21]  chromatic lookup (3 octaves)
--   sadj[1..7] live micro-adjust (runtime only, not saved)
--   asd        active scale preset 1-16
--   SD[1..16]  scale presets (1-7 modes, 8-16 chromatic)
--
-- ------------------------------------------------------------
-- KEY FUNCTIONS  (see section banners below)
-- ------------------------------------------------------------
--   bsc()        rebuild cs[] from sr + si[]
--   adv(t)       advance track t one tick
--   tka()        main tick handler (internal or midi clock)
--   son / sof    note on / off per track
--   mnf(t,s)     compute midi note for track/step
--   ldp(p,sy)    load pattern (sy=false = cue, else direct)
--   svp(p)       save current state into ram slot p
--   cap / rst    serialise / restore pattern string
--   rd()         full grid redraw
--   pts / rts    transport play-toggle / reset
-- ============================================================


-- ============================================================
-- BOOT
-- ============================================================
collectgarbage("collect")

-- ============================================================
-- CONSTANTS
-- ============================================================
STEPS=16 PPQN=24
tro=6 tfi=0 cpd=0.125
TCH={1,2,3,4}
MC8={0xF8} MCA={0xFA} MCC={0xFC} gcc=0
DV={1,2,3,4,5,6,7,8,10,12,14,16,20,24,28,32}
SD={{2,2,1,2,2,2,1},{2,1,2,2,2,1,2},{1,2,2,2,1,2,2},{2,2,2,1,2,2,1},{2,2,1,2,2,1,2},{2,1,2,2,1,2,2},{1,2,2,1,2,2,2}}
local _c={1,1,1,1,1,1,1} for i=8,16 do SD[i]=_c end
SDF="2212221212221212221222221221221221221221221221222"
function gSDR(s) local t={} for i=1,7 do local c=SDF:byte((s-1)*7+i) t[i]=c and c-48 or 1 end return t end
F=0 D=3 M=7 H=11 BF=15
ODR=5
OR={[2]=36,[3]=24,[4]=12,[5]=0,[6]=-12,[7]=-24}
GO={-24,-12,0,12,24,36,48,60}
NP=16
DM={1,.937,.875,.812,.75,.687,.625,.562,.5,.437,.375,.312,.25,.187,.125,.0625}
PV={0,1,2,4}
sr=48 si={2,2,1,2,2,2,1} asd=1 cs={}
sadj={0,0,0,0,0,0,0}
shk=nil

-- ============================================================
-- API ALIASES  (short names for hot-path calls)
-- ============================================================
gl=grid_led gr=grid_refresh cg=collectgarbage mr=math.random tu=table.unpack SC=string.char mx=math.max mf=math.floor

-- ============================================================
-- SCALE / RATCHET / TIMING HELPERS
-- ============================================================
-- bsc()       build chromatic lookup cs[] from sr + si[]
-- gSDR(s)     decode scale preset s (8-16, chromatic) from SDF
-- rget/rset   read/write a ratchet slot bit in rsl[t][s]
-- ucpd()      recompute clock period cpd from tro (coarse) + tfi (fine)
-- ublk()      clear the blink flag (used by ratchet/alt-note pages)
-- nls(t,s)    gate length in seconds for track t, step s
function bsc()
cs[1]=sr
for i=2,7 do cs[i]=cs[i-1]+si[i-1] end
for i=8,14 do cs[i]=cs[i-7]+12 end
for i=15,21 do cs[i]=cs[i-14]+24 end
end
function rget(t,s,i) return rsl[t][s] & (1 << (i-1)) ~= 0 end
function rset(t,s,i,v)
if v then rsl[t][s] = rsl[t][s] | (1 << (i-1))
else rsl[t][s] = rsl[t][s] & ~(1 << (i-1)) end
end
function ucpd() local b=tro<7 and 30+tro*15 or 120+(tro-6)*20 cpd=15/(b+tfi) if tr2 and not ms then icl.time=cpd end end
function ublk() blk=false end
function nls(t,s)
local st=cpd local r=du[t][s] or 1 local m=DM[17-gdu[t]] or 1
if r>=5 then return st*m end
return mx(st*((r-1)/4)*m,.02)
end
-- ============================================================
-- ALT-NOTE LOOP & PLAYHEAD
-- ============================================================
-- aliw/ainl/allen   loop-wrap predicates & length for alt-note loop
-- anxs(t)           next alt-note step for track t (honours sdir)
-- adva(t)           advance alt-note playhead every DV[adv2[t]] ticks
function aliw(t) return als[t]>ale[t] end
function ainl(t,s)
if aliw(t) then return s>=als[t] or s<=ale[t] else return s>=als[t] and s<=ale[t] end
end
function allen(t)
if aliw(t) then return STEPS-als[t]+ale[t]+1 else return ale[t]-als[t]+1 end
end
function anxs(t)
local s=aph[t] or 1
local d=sdir[t] or 1
if addr[t]==nil then addr[t]=1 end
if d==1 then
s=s+1
if aliw(t) then
if s>STEPS then s=1 end
if s>ale[t] and s<als[t] then s=als[t] end
else
if s>ale[t] or s>STEPS then s=als[t] end
end
elseif d==2 then
s=s-1 if s<1 then s=STEPS end
if aliw(t) then if s>ale[t] and s<als[t] then s=ale[t] end
else if s<als[t] or s>ale[t] then s=ale[t] end end
elseif d==3 then
s=s+addr[t]
if s>ale[t] then s=ale[t] addr[t]=-1
elseif s<als[t] then s=als[t] addr[t]=1 end
elseif d==4 then
addr[t]=(mr(2)==1) and 1 or -1 s=s+addr[t]
if aliw(t) then
if s<1 then s=STEPS end if s>STEPS then s=1 end
if s>ale[t] and s<als[t] then s=als[t] end
else
if s<als[t] then s=ale[t] elseif s>ale[t] then s=als[t] end
end
elseif d==5 then
s=als[t]+mr(allen(t))-1
if aliw(t) and s>STEPS then s=s-STEPS end
end
return s
end
function adva(t)
adc[t]=(adc[t] or 0)+1
if adc[t]<DV[adv2[t] or 1] then return end
adc[t]=0
aph[t]=anxs(t)
end
-- ============================================================
-- MIDI NOTE OUTPUT
-- ============================================================
-- mnf(t,s)  midi note = cs[note] + octave + global-octave + sadj
-- son(t,s)  fire note-on, schedule note-off via nom[t] metro
-- sof(t)    kill the currently-playing note on track t
-- ano()     all notes off
function mnf(t,s)
local ni=no[t][s] or 1
local as=aph[t] or 1
local av=an2[t][as]
if av~=nil and av>0 then
ni=ni+av
end
local adj=sadj[((ni-1)%7)+1] or 0
return clamp((cs[ni] or sr)+adj+(OR[oc[t][s]] or 0)+(GO[go2[t]] or 0),0,127)
end
function son(t,s)
if mute[t] then return end
local mn=mnf(t,s)
if an[t]>=0 then midi_note_off(an[t],0,TCH[t]) nom[t]:stop() end
midi_note_on(mn,100,TCH[t]) an[t]=mn nom[t]:start(nls(t,s))
end
function sof(t)
if an[t]>=0 then midi_note_off(an[t],0,TCH[t]) an[t]=-1 nom[t]:stop() end
end
function ano() for t=1,4 do sof(t) end end
-- ============================================================
-- TRIGGER LOOP & PLAYHEAD
-- ============================================================
-- liw/inl/llen   same predicates but for the trigger loop ls/le
-- nxs(t)         next trigger step (honours sdir)
function liw(t) return ls[t]>le[t] end
function inl(t,s)
if liw(t) then return s>=ls[t] or s<=le[t] else return s>=ls[t] and s<=le[t] end
end
function llen(t)
if liw(t) then return STEPS-ls[t]+le[t]+1 else return le[t]-ls[t]+1 end
end
function nxs(t)
local s=ph[t] or 1 local d=sdir[t] or 1
if ddr[t]==nil then ddr[t]=1 end
if d==1 then
s=s+1
if liw(t) then
if s>STEPS then s=1 end
if s>le[t] and s<ls[t] then s=ls[t] end
else
if s>le[t] or s>STEPS then s=ls[t] end
end
elseif d==2 then
s=s-1 if s<1 then s=STEPS end
if liw(t) then if s>le[t] and s<ls[t] then s=le[t] end
else if s<ls[t] or s>le[t] then s=le[t] end end
elseif d==3 then
s=s+ddr[t]
if s>le[t] then s=le[t] ddr[t]=-1
elseif s<ls[t] then s=ls[t] ddr[t]=1 end
elseif d==4 then
ddr[t]=(mr(2)==1) and 1 or -1 s=s+ddr[t]
if liw(t) then
if s<1 then s=STEPS end if s>STEPS then s=1 end
if s>le[t] and s<ls[t] then s=ls[t] end
else
if s<ls[t] then s=le[t] elseif s>le[t] then s=ls[t] end
end
elseif d==5 then
s=ls[t]+mr(llen(t))-1
if liw(t) and s>STEPS then s=s-STEPS end
end
return s
end
-- ============================================================
-- STEP ADVANCE
-- ============================================================
-- pld          pattern-load flag: suppresses playhead advance on the
--              first tick after a cued/direct pattern load, so the
--              new pattern starts cleanly from its loop start.
-- advnph(t)    advance the note-quantise playhead (tclk mode)
-- adv(t)       advance one track by one tick; fires son/sof,
--              checks probability, schedules ratchet bursts
pld=false
function advnph(t)
local s=nph[t]+1
if aliw(t) then
if s>STEPS then s=1 end
if s>ale[t] and s<als[t] then s=als[t] end
else if s>ale[t] or s>STEPS then s=als[t] end end
nph[t]=s
end
function adv(t)
dc[t]=(dc[t] or 0)+1
if dc[t]<DV[dv2[t] or 1] then return false end
dc[t]=0
if not pld then ph[t]=nxs(t) adva(t) end
if mute[t] then sof(t) return true end
if tr[t][ph[t]] then
if mr(4)<=PV[prb[t][ph[t]] or 4] then
local nd=rdv[t][ph[t]] or 1
local ns=tclk[t] and nph[t] or ph[t]
if nd<=1 then
if rget(t,ph[t],1) then son(t,ns) if tclk[t] and not pld then advnph(t) end else sof(t) end
else
sof(t) rsc[t]=0
local ri=mx(cpd/nd,.02)
rsc[t]=1
if rget(t,ph[t],1) then son(t,ns) if tclk[t] and not pld then advnph(t) end end
if nd>1 then ram[t]:start(ri) end
end
else sof(t) end
else sof(t) end
return true
end
-- ============================================================
-- MAIN TICK & CLOCK METRO
-- ============================================================
-- tka()   main tick: fires each PPQN. advances every track, sends
--         midi clock if we're master, handles cued pattern loads,
--         schedules grid redraws. called by icl (internal clock)
--         or by event_midi on 0xF8 (external clock).
-- sic()   (re)start the internal clock metro at cpd
-- stc()   stop the internal clock metro (used when ms=true)
function tka()
if not tr2 and ms then return end
cpls=not cpls
cbt=(cbt+1)%4
if not ms then midi_out(MC8) end
gcc=gcc+1
if gcc>=64 then gcc=0 cg("step",1) end
local upd=cbt==0
for t=1,4 do if adv(t) then upd=true end end
pld=false
if cman then
ccc=ccc+1
if ccc>=cclk then
if cued then ldp(cued,false) cued=nil end
ccc=0
end
else
local mx2=0
for t=1,4 do
local len=llen(t)*(DV[dv2[t] or 1] or 1)
if len>mx2 then mx2=len clt=t end
end
cclk=llen(clt)
cdc=cdc+1
if cdc>=(DV[dv2[clt] or 1] or 1) then
cdc=0
ccc=ccc+1
if ccc>=cclk then
if cued then ldp(cued,false) cued=nil end
ccc=0
end
end
end
if upd then rd() end
end
function sic() icl:stop() icl:start(cpd) end
function stc() icl:stop() end
-- ============================================================
-- EXTERNAL MIDI CLOCK INPUT
-- ============================================================
-- 0xF8  clock tick   (measure period, drive tka every sp ticks)
-- 0xFA  start        (also 0xFB continue)
-- 0xFC  stop
-- when external clock arrives we set ms=true and stop the
-- internal metro; pt[] holds recent tick timestamps for
-- period smoothing into cpd.
function event_midi(b1,b2,b3)
if b1==0xF8 then
if not tr2 then return end
local now=get_time() table.insert(pt,now)
if #pt>PB then table.remove(pt,1) end
if not ms then ms=true stc() cp=0 for t=1,4 do dc[t]=0 adc[t]=0 end end
if #pt>=2 then cpd=((pt[#pt]-pt[1])/(#pt-1))*sp end
cp=cp+1 if cp>=sp then cp=0 tka() end
elseif b1==0xFA or b1==0xFB then
ms=true tr2=true stc() cp=0 pt={} cbt=0 cpls=false ccc=0
for t=1,4 do
ph[t]=(sdir[t]==2 and le[t] or ls[t]) dc[t]=0 aph[t]=(sdir[t]==2 and ale[t] or als[t]) adc[t]=0 nph[t]=als[t]
if tr[t][ph[t]] then son(t,ph[t]) else sof(t) end
end
rd()
elseif b1==0xFC then tr2=false ms=false pt={} ucpd() ano()
for t=1,4 do ph[t]=(sdir[t]==2 and le[t] or ls[t]) aph[t]=(sdir[t]==2 and ale[t] or als[t]) nph[t]=als[t] end
rd()
end
end
-- ============================================================
-- PATTERN SERIALISE / RESTORE
-- ============================================================
-- cap()   pack current state into a compact byte string
--         layout: 4 tracks x 16 steps x 8 bytes + loop + scale
--                 + globals + sync flags (see rst for offsets)
-- rst(d)  unpack a string back into live state tables
function cap()
local b={} local n=0
for t=1,4 do
for s=1,STEPS do
n=n+1
b[n]=SC((tr[t][s] and 1 or 0),no[t][s],oc[t][s],du[t][s],prb[t][s],rdv[t][s],rsl[t][s],an2[t][s]+50)
end
n=n+1
b[n]=SC(ph[t],ls[t],le[t],dv2[t],aph[t],als[t],ale[t],adv2[t])
end
n=n+1 b[n]=SC(sr,asd)
for i=1,7 do n=n+1 b[n]=SC(si[i]) end
n=n+1 b[n]=SC(go2[1],go2[2],go2[3],go2[4])
n=n+1 b[n]=SC(gdu[1],gdu[2],gdu[3],gdu[4])
n=n+1 b[n]=SC(sdir[1],sdir[2],sdir[3],sdir[4])
n=n+1 b[n]=SC(mute[1] and 1 or 0,mute[2] and 1 or 0,mute[3] and 1 or 0,mute[4] and 1 or 0)
for t=1,4 do
for s=1,STEPS do n=n+1 b[n]=SC(4) end
end
n=n+1 b[n]=SC(tclk[1] and 1 or 0,tclk[2] and 1 or 0,tclk[3] and 1 or 0,tclk[4] and 1 or 0)
n=n+1 b[n]=SC(nsyn and 1 or 0,lsyn)
return table.concat(b)
end
function rst(d)
if type(d)~="string" then return end
local B=string.byte
for t=1,4 do
local tb=(t-1)*136
for s=1,STEPS do
local o=tb+(s-1)*8
tr[t][s]=B(d,o+1)==1
no[t][s]=B(d,o+2)
local ov=B(d,o+3)
if ov<2 or ov>7 then ov=ODR end
oc[t][s]=ov
local dv=B(d,o+4)
if dv>5 then dv=1 end
du[t][s]=dv
prb[t][s]=clamp(B(d,o+5) or 4,1,4)
rdv[t][s]=clamp(B(d,o+6) or 1,1,5)
rsl[t][s]=B(d,o+7) or 1
an2[t][s]=(B(d,o+8) or 49)-50
end
local b=tb+128
ph[t]=clamp(B(d,b+1) or 1,1,STEPS)
ls[t]=clamp(B(d,b+2) or 1,1,STEPS)
le[t]=clamp(B(d,b+3) or STEPS,1,STEPS)
dv2[t]=clamp(B(d,b+4) or 1,1,16)
aph[t]=clamp(B(d,b+5) or 1,1,STEPS)
als[t]=clamp(B(d,b+6) or 1,1,STEPS)
ale[t]=clamp(B(d,b+7) or STEPS,1,STEPS)
adv2[t]=clamp(B(d,b+8) or 1,1,16)
ddr[t]=1 dc[t]=0 adc[t]=0 addr[t]=1 nph[t]=als[t]
end
local g=544
sr=B(d,g+1) asd=B(d,g+2)
for i=1,7 do si[i]=B(d,g+2+i) end
local q=g+9
for t=1,4 do go2[t]=clamp(B(d,q+t),1,8) gdu[t]=clamp(B(d,q+4+t),1,16) sdir[t]=clamp(B(d,q+8+t),1,5) mute[t]=B(d,q+12+t)==1 end
if #d>=637 then for t=1,4 do tclk[t]=B(d,633+t)==1 end end
if #d>=639 then nsyn=B(d,638)==1 lsyn=B(d,639) end
if asd<1 or asd>16 then asd=1 end
bsc() crs() scph=nil shk=nil
end
-- ============================================================
-- PATTERN LOAD / SAVE  (RAM slots)
-- ============================================================
-- pats[p]   serialised pattern string per slot (1..NP)
-- psx[p]    slot-occupied flag, used by dpat to dim empty slots
-- ldp(p,s)  load slot p; s=false = cued (waits for ccc to wrap)
--           s=nil/true = direct load with pld (playhead resync)
-- svp(p)    capture current state into slot p (ram only)
-- crs()     clear live scale micro-adjust sadj[]
function ldp(p,sync)
if pats[p] then rst(pats[p])
else
for t=1,4 do
for s=1,STEPS do
tr[t][s]=false no[t][s]=1 oc[t][s]=ODR du[t][s]=0 prb[t][s]=4
rdv[t][s]=1 rsl[t][s]=1 an2[t][s]=-1
end
ph[t]=1 ls[t]=1 le[t]=STEPS dv2[t]=1 dc[t]=0
aph[t]=1 als[t]=1 ale[t]=STEPS adv2[t]=1 adc[t]=0 addr[t]=1 nph[t]=1 tclk[t]=false
end
end
ap=p if sync~=false then ccc=0 end
if sync~=false then ano() end
for t=1,4 do ram[t]:stop() rsc[t]=0 end
for t=1,4 do ph[t]=(sdir[t]==2 and le[t] or ls[t]) aph[t]=(sdir[t]==2 and ale[t] or als[t]) adc[t]=0 nph[t]=als[t]
if sync==false then dc[t]=0 sof(t) if tr[t][ph[t]] then son(t,ph[t]) end
else dc[t]=DV[dv2[t] or 1]-1 end end
if sync~=false then pld=true end
end
function svp(p)
pats[p]=nil cg("collect")
pats[p]=cap() psx[p]=true
cg("collect")
end
function crs() for i=1,7 do sadj[i]=0 end end
-- ============================================================
-- PSET FILE I/O  (disk persistence via iii pset_* API)
-- ============================================================
-- pinit()     one-shot pset_init("ki") guard
-- hx/dhx      hex-encode / decode a pattern string for pset_write
-- fsave(p)    write one slot to disk
-- fload()     read all NP slots from disk into pats[]
-- fsaveall()  write all occupied slots to disk
function pinit() if not psi then pset_init("ki") psi=true end end
function hx(s) return(s:gsub(".",function(c) return string.format("%02x",c:byte())end))end
function dhx(s) return(s:gsub("..",function(h) return SC(tonumber(h,16))end))end
function fsave(p)
pinit()
if pats[p] then pcall(pset_write,p,hx(pats[p])) end
end
function fload()
pinit()
for p=1,NP do
pats[p]=nil cg("collect")
local ok,d=pcall(pset_read,p)
if ok and d and type(d)=="string" and #d>=1138 then pats[p]=dhx(d) psx[p]=true end
end
cg("collect")
end
function fsaveall()
pinit()
for p=1,NP do
if pats[p] then pcall(pset_write,p,hx(pats[p])) end
cg("collect")
end
end
-- ============================================================
-- GRID DRAW  (per-page renderers + overlays)
-- ============================================================
-- dnav   nav row (y=8) - track select/mute, pages, overlays, transport
-- dtr    trigger page (vm=1)
-- dno    note page (vm=2)
-- dano   alt-note page (vm=12)
-- doc    octave page (vm=3)
-- ddu    duration page (vm=4)
-- drch   ratchet page (vm=11)
-- dsc    scale page (vm=6)
-- dprb   probability overlay (mph held)
-- dpat   pattern page (vm=7)
-- dcfg   config hold page (cfh)
-- dtim   time hold page (tmh)
-- dlp    loop overlay (mlh held)
-- dtm    time-div overlay (mth held)
-- rd     main dispatcher: clears, picks renderer by vm/holds, refreshes
function dnav()
for x=1,16 do gl(x,8,F) end
for t=1,4 do
local b
if t==at then b=mute[t] and 8 or BF
else b=mute[t] and 1 or 5 end
gl(t,8,b)
end
for i=1,4 do
local b
if vm==11 and i==1 then b=blk and BF or D
elseif vm==12 and i==2 then b=blk and BF or D
elseif vm==i then b=BF
else b=D end
gl(5+i,8,b)
end
gl(11,8,mlh and BF or D)
gl(12,8,mth and BF or D)
gl(13,8,mph and BF or D)
gl(15,8,(vm==6) and BF or D)
gl(16,8,(vm==7) and BF or (tr2 and (cbt==0 and BF or (cpls and M or D)) or D))
end
function dtr()
for t=1,4 do
local mu=mute[t] local sel=(t==at)
for s=1,STEPS do
local b
if s==ph[t] then b=tr2 and (mu and M or BF) or M
elseif inl(t,s) then
if tr[t][s] then b=mu and M or M
else b=sel and D or 1 end
else b=tr[t][s] and (mu and 1 or D) or F end
gl(s,t,b)
end
end
gl(6,7,D)
gl(7,7,D)
gl(15,7,tr2 and BF or D)
gl(16,7,D)
end
function dno()
local np=tclk[at] and nph[at] or ph[at]
local il=tclk[at] and ainl or inl
for r=1,7 do
local si2=(7-r)+1
for s=1,STEPS do
local b
local hn=no[at][s]==si2
local ht=tr[at][s]
local iph=tr2 and s==np
if hn and (ht or not nsyn) then
if iph then b=BF elseif il(at,s) then b=ht and H or D else b=ht and M or D end
elseif iph then b=D elseif r==7 then b=(not nsyn and ht) and D or 1 else b=F end
gl(s,r,b)
end
end
end
function dano()
for r=1,7 do
local av=7-r
for s=1,STEPS do
local b
if an2[at][s]==av then
if tr2 and s==aph[at] then b=BF elseif ainl(at,s) then b=H else b=M end
else
if r==7 then
if an2[at][s]==-1 then
b=(tr2 and s==aph[at]) and D or (tr[at][s] and 5 or 1)
else
b=(tr2 and s==aph[at]) and D or F
end
else
b=(tr2 and s==aph[at]) and D or F
end
end
gl(s,r,b)
end
end
end
function doc()
for x=1,16 do gl(x,1,F) end
for c=1,8 do gl(c,1,(c==go2[at]) and BF or D) end
for s=1,STEPS do
local sel=oc[at][s] local iph=(tr2 and s==ph[at]) local itr=tr[at][s]
for r=2,7 do
local b local inf
if sel<5 then inf=(r>=sel and r<=5)
elseif sel>5 then inf=(r>=5 and r<=sel)
else inf=(r==5) end
if r==sel then
if iph then b=BF elseif itr then b=H else b=F end
elseif inf then
if iph then b=M elseif itr then b=D else b=F end
else
if r==5 then
if sel==5 then
if iph then b=BF elseif itr then b=H else b=1 end
else b=iph and D or 1 end
else b=iph and D or F end
end
gl(s,r,b)
end
end
end
function ddu()
for s=1,STEPS do
local sel=du[at][s] local iph=(tr2 and s==ph[at]) local itr=tr[at][s]
for r=1,7 do
local b
if r==1 then
if s==gdu[at] then b=BF
else b=F end
elseif r==2 then
if iph then b=10
elseif itr then b=D
else b=F end
else
if itr and sel>0 and r<=sel+2 then
if iph then b=10 else b=D end
else b=F end
end
gl(s,r,b)
end
end
end
function drch()
for s=1,STEPS do
local nd=rdv[at][s] or 1
local iph=(tr2 and s==ph[at]) local itr=tr[at][s]
gl(s,1,iph and M or D)
for r=2,6 do
local slot=7-r
local b
if slot<=nd then
if rget(at,s,slot) then
if iph then b=BF elseif itr then b=H else b=D end
else
if iph then b=M else b=D end
end
else b=iph and 1 or F end
gl(s,r,b)
end
gl(s,7,iph and M or D)
end
end
function dsc()
if sch then
for x=1,16 do gl(x,sch,(x==TCH[sch]) and BF or D) end
for t=1,4 do if t~=sch then gl(1,t,D) end end
else
for t=1,4 do gl(1,t,D) end
end
for t=1,4 do
if t~=sch then
gl(2,t,tclk[t] and BF or D)
for c=4,8 do gl(c,t,(sdir[t]==c-3) and BF or D) end
end
end
for i=1,8 do gl(i,6,(i==asd) and BF or D) end
for i=1,8 do gl(i,7,(i+8==asd) and BF or D) end
local ro=(sr-48)%12
for c=9,16 do
local s2=c-9
if s2==ro then gl(c,7,BF)
elseif s2==0 then gl(c,7,D)
else gl(c,7,F) end
end
for r=1,6 do
if r~=sch then
local idx=7-r
local iv=si[idx]
local ni=8-r
local adj=sadj[ni] or 0
for c=9,16 do
local s2=c-9
if s2==iv then gl(c,r,BF)
elseif adj~=0 and s2==(iv+adj)%8 then gl(c,r,D)
elseif s2==0 then gl(c,r,1)
else gl(c,r,F) end
end
end
end
end
function dprb()
for s=1,STEPS do
local p=prb[at][s] or 4
local sel=6-p
local iph=tr2 and s==ph[at]
local itr=tr[at][s]
for r=2,5 do
local b
if r==sel then
if iph then b=BF elseif itr then b=H else b=D end
elseif r>sel then
if iph then b=M else b=D end
else b=iph and D or F end
gl(s,r,b)
end
end
end
function dpat()
if pflash>0 then pflash=pflash-1 end
for p=1,NP do
local b
if pflash>0 and (p==pflx or pflx==-1) then b=BF
elseif p==ap then b=H
elseif cued and p==cued then b=9
elseif psx[p] then b=5 else b=1 end
gl(p,1,b)
end
if cclk<1 then cclk=1 end
local cpos=ccc%cclk
for x=1,16 do
local b=F
if tr2 and x==cpos+1 then b=13
elseif x==cclk then b=4
elseif x<=cclk then b=1 end
gl(x,2,b)
end
gl(1,7,fldfl and BF or D)
gl(2,7,pclh and H or 1)
gl(3,7,fsafl and BF or D)
gl(15,7,tr2 and BF or D)
gl(16,7,D)
end
function dcfg()
local nb=nsyn and H or D
for r=3,6 do for c=2,5 do
if r==3 or r==6 or c==2 or c==5 then gl(c,r,nb) end
end end
gl(12,3,lsyn==1 and BF or D)
for c=11,14 do gl(c,6,lsyn==2 and BF or D) end
end
function dtim()
local pb=cbt==0 and BF or D
if ms then
gl(8,1,pb)
for x=1,16 do gl(x,2,(x==sp) and BF or D) end
else
gl(8,1,pb)
for x=1,16 do gl(x,2,(x==tro+1) and BF or D) end
for x=1,16 do gl(x,3,(x==tfi+1) and BF or D) end
gl(7,4,D) gl(8,4,D) gl(9,4,D) gl(10,4,D)
end
end
function dlp()
local nm=vm==2 or vm==12
for t=1,4 do
local lw=nm and als[t] or ls[t]
local lx=nm and ale[t] or le[t]
local wr=liw(t) if nm then wr=aliw(t) end
for s=1,STEPS do
local b local iep=(s==lw or s==lx) local iin
if wr then iin=(s>lw or s<lx) else iin=(s>lw and s<lx) end
local sph=nm and aph[t] or ph[t]
if tr2 and s==sph then b=BF
elseif iep then b=(t==at) and BF or H
elseif iin then b=(t==at) and M or D
else b=F end
if lft==t and lfc==s then b=BF end
gl(s,t,b)
end
end
end
function dtm()
for t=1,4 do
local sel=(t==at)
local dv=vm==12 and sel and adv2[t] or dv2[t]
for x=1,16 do
local b=F
if x==dv then b=sel and BF or H
else b=sel and D or 1 end
gl(x,t,b)
end
end
end
-- ------------------------------------------------------------
-- rd : main redraw dispatcher (called any time state changes)
-- ------------------------------------------------------------
function rd()
cg("step",1)
if vm==11 or vm==12 then blk=not blk end
grid_led_all(F)
if cfh then dcfg()
elseif tmh then dtim()
else
dnav()
if mlh then dlp()
elseif mth then dtm()
elseif mph then dprb()
elseif vm==11 then drch()
elseif vm==12 then dano()
elseif vm==1 then dtr()
elseif vm==2 then dno()
elseif vm==3 then doc()
elseif vm==4 then ddu()
elseif vm==6 then dsc()
elseif vm==7 then dpat()
end
end
gr()
end
-- ============================================================
-- TRANSPORT & TEMPO
-- ============================================================
-- pts()    play / stop toggle (internal clock only; ext clock
--          transport is driven by event_midi on 0xFA/0xFC)
-- rts()    reset all playheads to their loop starts, retrigger
-- tadj(k)  tempo fine-adjust nudge (keys 7-10 on time page)
function pts()
if not ms then
if tr2 then tr2=false ano() stc() midi_out(MCC)
for t=1,4 do ph[t]=(sdir[t]==2 and le[t] or ls[t]) aph[t]=(sdir[t]==2 and ale[t] or als[t]) nph[t]=als[t] end
else tr2=true cbt=0 cpls=false ccc=0
for t=1,4 do ph[t]=(sdir[t]==2 and le[t] or ls[t]) dc[t]=DV[dv2[t] or 1]-1 aph[t]=(sdir[t]==2 and ale[t] or als[t]) adc[t]=0 nph[t]=als[t] end
pld=true ucpd() sic() midi_out(MCA) end
rd() end
end
function rts()
ccc=0
for t=1,4 do ph[t]=(sdir[t]==2 and le[t] or ls[t]) dc[t]=0 aph[t]=(sdir[t]==2 and ale[t] or als[t]) adc[t]=0 nph[t]=als[t] end
if tr2 then
for t=1,4 do if not mute[t] and tr[t][ph[t]] then son(t,ph[t]) end end
end
rd() gl(16,7,BF) gr()
end
function tadj(k)
local d=k==7 and -4 or k==8 and -1 or k==9 and 1 or 4
tfi=tfi+d
if tfi>15 then if tro<15 then tro=tro+1 tfi=0 else tfi=15 end
elseif tfi<0 then if tro>0 then tro=tro-1 tfi=15 else tfi=0 end end
ucpd() rd()
end
-- ============================================================
-- GRID INPUT HANDLER
-- ============================================================
-- event_grid(x,y,z) is the single entry point for all key events.
-- structure (top to bottom):
--   1. nav row (y=8)            - page switch, mute, overlay holds
--   2. mlh/mth/mph overlays     - edits on top of active page
--   3. ratchet page (vm=11)     - long-press grow/shrink rows
--   4. alt-note page (vm=12)
--   5. config/time holds        - cfh/tmh detail pages
--   6. pattern page releases    - save/load/clear timers on z=0
--   7. per-page z=1 edits       - tr/no/oc/du/sc/pat
-- all branches end with rd() to repaint on change.
function event_grid(x,y,z)
-- ---- nav row (y=8) ----
if y==8 then
if x==11 then
mlh=(z==1)
if z==0 then lfc=nil lft=nil end
rd() return
end
if x==12 then mth=(z==1) rd() return end
if x==13 then mph=(z==1) rd() return end
if x==15 then
if z==1 then
ublk()
if vm~=6 then vm=6 end
shld=true
else shld=false end
rd() return
end
if x==16 then
if z==1 then
ublk()
vm=7 pth=true
else pth=false end
rd() return
end
if z==0 then
if x>=1 and x<=4 then cpt=nil clrt=nil shm:stop() end
return
end
if mlh and x>=1 and x<=4 then
mute[x]=not mute[x]
if mute[x] then sof(x) end
rd() return
end
if x>=1 and x<=4 then
if cpt and cpt~=x then
if vm==1 or vm==11 then
for s=1,STEPS do tr[x][s]=tr[cpt][s] end
elseif vm==2 or vm==12 then
for s=1,STEPS do no[x][s]=no[cpt][s] tr[x][s]=tr[cpt][s] end
elseif vm==3 then
for s=1,STEPS do oc[x][s]=oc[cpt][s] end
elseif vm==4 then
for s=1,STEPS do du[x][s]=du[cpt][s] end
end
at=x cpt=nil clrt=nil shm:stop() rd()
gl(x,8,BF) gr()
return
end
at=x cpt=x
if vm>=1 and vm<=4 or vm==11 or vm==12 then clrt=x shm:stop() shm:start(2.0) end
elseif x==6 then
if vm==1 then vm=11
elseif vm==11 then vm=1 blk=false
else ublk() vm=1 end
elseif x==7 then
if vm==2 then vm=12
elseif vm==12 then vm=2 blk=false
else ublk() vm=2 end
elseif x==8 then
ublk() vm=3
elseif x==9 then
ublk() vm=4
end
rd() return
end
if mlh then
if y>=1 and y<=4 and x>=1 and x<=STEPS then
local t=y
if z==1 then
local nm=vm==2 or vm==12
if lft==nil then
lft=t lfc=x
if nm then als[t]=x ale[t]=x else ls[t]=x le[t]=x end
else
local lf=lft
if nm then als[lf]=lfc ale[lf]=x
if not ainl(lf,aph[lf]) then aph[lf]=lfc end
else ls[lf]=lfc le[lf]=x
if not inl(lf,ph[lf]) then ph[lf]=lfc end end
end
local ref=lft or t
local P1,P2=nm and als or ls,nm and ale or le
local Q1,Q2=nm and ls or als,nm and le or ale
if lsyn==2 then for tt=1,4 do P1[tt]=P1[ref] P2[tt]=P2[ref] Q1[tt]=P1[tt] Q2[tt]=P2[tt] end
else if lsyn==1 or nsyn then Q1[ref]=P1[ref] Q2[ref]=P2[ref] end end
else
if lft==t and lfc==x then lft=nil lfc=nil end
end
rd()
end
return
end
if mth then
if z==0 then return end
if y>=1 and y<=4 and x>=1 and x<=16 then
if vm==12 and y==at then adv2[at]=x adc[at]=0
else dv2[y]=x dc[y]=0 end
rd()
end
return
end
if mph then
if z==0 then return end
if y>=2 and y<=5 and x>=1 and x<=STEPS then
prb[at][x]=6-y
rd()
end
return
end
if vm==11 then
if z==1 and (y==1 or y==7) then
rchy=y rchx=x shm:start(HT)
return
end
if z==0 then
if (y==1 or y==7) and rchx==x and rchy==y then
shm:stop()
if y==1 then
local nd=(rdv[at][x] or 1)+1
if nd>5 then nd=5 end
rdv[at][x]=nd rset(at,x,nd,true)
elseif y==7 then
local nd=(rdv[at][x] or 1)-1
if nd<1 then nd=1 end
rdv[at][x]=nd
rset(at,x,nd+1,false)
if not rget(at,x,1) then rset(at,x,1,true) end
end
rchy=nil rchx=nil rd()
elseif rchy==y then
shm:stop() rchy=nil rchx=nil
end
return
end
if y>=2 and y<=6 and x>=1 and x<=STEPS and z==1 then
local slot=7-y
local nd=rdv[at][x] or 1
if slot>nd then
for i=nd+1,slot-1 do rset(at,x,i,false) end
rdv[at][x]=slot
rset(at,x,slot,true)
else
rset(at,x,slot,not rget(at,x,slot))
nd=rdv[at][x]
while nd>1 and not rget(at,x,nd) do nd=nd-1 end
rdv[at][x]=nd
end
rd()
end
return
end
if vm==12 then
if z==0 then return end
if y>=1 and y<=7 and x>=1 and x<=STEPS then
if y==7 then
an2[at][x]=-1
else
local av=7-y
if an2[at][x]==av then
an2[at][x]=-1
else
an2[at][x]=av
end
end
rd()
end
return
end
if z==1 then kvm=vm end
if vm==6 and z==0 then
if shk and shk[1]==y and shk[2]==x then shk=nil end
if scph and scph[1]==y and scph[2]==x then scph=nil end
if sch and x==1 and y==sch then
if scfc==0 then TCH[sch]=1 end
sch=nil rd()
end
return
end
if y==7 and x==7 and (vm==1 or cfh) then
cfh=(z==1)
rd() return
end
if y==7 and x==6 and (vm==1 or tmh) then
tmh=(z==1)
if not tmh then thk=nil shm:stop() end
rd() return
end
if cfh then
if z==0 then return end
if y>=3 and y<=6 and x>=2 and x<=5 then
nsyn=not nsyn rd()
elseif y==3 and x==12 then
lsyn=(lsyn==1) and 0 or 1 rd()
elseif y==6 and x>=11 and x<=14 then
lsyn=(lsyn==2) and 0 or 2 rd()
end
return
end
if tmh then
if not ms then
if z==1 then
if y==2 and x>=1 and x<=16 then
tro=x-1 ucpd() rd()
elseif y==3 and x>=1 and x<=16 then
tfi=x-1 ucpd() rd()
elseif y==4 and x>=7 and x<=10 then
tadj(x) thk=x shm:start(0.4)
end
elseif z==0 then
if y==4 and thk then thk=nil shm:stop() end
end
else
if z==1 and y==2 and x>=1 and x<=16 then
sp=x rd()
end
end
return
end
if z==0 then
if vm==7 and y==1 and phl then
if phl==x then
shm:stop()
ccc=0 cdc=0 cman=false
ldp(x) rd()
end
phl=nil
end
if fsh and vm==7 and y==1 then
if get_time()-fsh[1]>=3.0 then
fsave(fsh[2])
pflx=fsh[2] pflash=12 rd()
end
fsh=nil
end
if vm==7 and y==7 and x==1 and fld then
if fldfl then fload() rd() end
fld=nil fldfl=false shm:stop()
end
if vm==7 and y==7 and x==2 then
pclh=false rd()
end
if vm==7 and y==7 and x==3 and fsa then
if fsafl then fsaveall() rd() end
fsa=nil fsafl=false shm:stop()
end
return
end
if vm==1 then
if y>=1 and y<=4 and x>=1 and x<=STEPS then
tr[y][x]=not tr[y][x]
if tr[y][x] then no[y][x]=1
else rdv[y][x]=1 rsl[y][x]=1 end
rd()
elseif y==7 and x==15 then pts()
elseif y==7 and x==16 then rts()
end
elseif vm==2 then
if y>=1 and y<=7 and x>=1 and x<=STEPS then
local si2=(7-y)+1
if nsyn then
if no[at][x]==si2 and tr[at][x] then tr[at][x]=false rdv[at][x]=1 rsl[at][x]=1
else no[at][x]=si2 tr[at][x]=true end
else
no[at][x]=si2
end
rd()
end
elseif vm==3 then
if y==1 and x>=1 and x<=8 then go2[at]=x rd()
elseif y>=2 and y<=7 and x>=1 and x<=STEPS then oc[at][x]=y rd() end
elseif vm==4 then
if y==1 and x>=1 and x<=16 then gdu[at]=x rd()
elseif y==2 and x>=1 and x<=STEPS then du[at][x]=0 rd()
elseif y>=3 and y<=7 and x>=1 and x<=STEPS then du[at][x]=y-2 rd() end
elseif vm==6 then
if y>=1 and y<=4 and x==1 and not sch then
sch=y scfc=0 rd()
elseif y>=1 and y<=4 and x==2 and not sch then
tclk[y]=not tclk[y] nph[y]=als[y] rd()
elseif sch and y==sch and x>=2 and x<=16 then
TCH[sch]=x scfc=x rd()
elseif (y==6 or y==7) and x>=1 and x<=8 then
local slot=y==6 and x or x+8
if shld then
SD[slot]=gSDR(slot)
if asd==slot then si={tu(SD[slot])} crs() end
elseif scph then
local src=scph[1]==6 and scph[2] or scph[2]+8
SD[slot]={tu(SD[src])}
if asd==slot then si={tu(SD[slot])} crs() end
shk=nil bsc() rd()
gl(x,y,BF) gr()
return
else
SD[asd]={tu(si)}
if slot~=asd then asd=slot si={tu(SD[slot])} crs() scph={y,x}
else gl(x,y,BF) gr() end
end
shk=nil bsc() rd()
elseif x>=4 and x<=8 and y>=1 and y<=4 then
sdir[y]=x-3 ddr[y]=1 rd()
elseif y==7 and x>=9 and x<=16 then
sr=48+(x-9) bsc() rd()
elseif x>=9 and x<=16 and y>=1 and y<=6 then
local idx=7-y
local ni=8-y
local nv=x-9
if shk and shk[1]==y then
sadj[ni]=nv-si[idx]
bsc() rd()
elseif shld and idx<6 then
local d=nv-si[idx] si[idx]=nv si[idx+1]=mx(si[idx+1]-d,0)
sadj[ni]=0 SD[asd]={tu(si)} bsc() rd()
else
si[idx]=nv sadj[ni]=0 SD[asd]={tu(si)} shk={y,x} bsc() rd()
end
end
elseif vm==7 then
if y==1 and x>=1 and x<=NP then
if pclh then
pats[x]=nil psx[x]=false
if ap==x then ap=1 end
cg("collect")
rd()
elseif pth then
cued=x rd()
else
phl=x shm:start(1.0)
end
elseif y==2 and x>=1 and x<=16 then
cclk=x cman=true rd()
elseif y==7 and x==1 then
fld=get_time() fldfl=false shm:stop() shm:start(2.0)
elseif y==7 and x==2 then
pclh=true rd()
elseif y==7 and x==3 then
fsa=get_time() fsafl=false shm:stop() shm:start(2.0)
elseif y==7 and x==15 then pts()
elseif y==7 and x==16 then rts()
end
end
end
-- ============================================================
-- INITIALISATION  (runs once at script load)
-- ============================================================
-- builds the chromatic lookup, zeroes every track/step,
-- creates the note-off, ratchet, internal-clock, and
-- multi-purpose (shm) metros, and paints the first frame.
bsc()
ap=1 pats={} psx={}
vm=1 at=1
nsyn=true lsyn=2
mlh=false mth=false mph=false cfh=false tmh=false lfc=nil lft=nil
tr={} no={} oc={} du={} ph={} ls={} le={} dv2={} dc={} an={}
go2={3,3,3,3} gdu={16,16,16,16} sdir={1,1,1,1} ddr={1,1,1,1}
mute={false,false,false,false}
prb={} rdv={} rsl={}
an2={} aph={} als={} ale={} adv2={} adc={} addr={}
tclk={false,false,false,false} nph={1,1,1,1}
blk=false
for t=1,4 do
tr[t]={} no[t]={} oc[t]={} du[t]={} prb[t]={} rdv[t]={} rsl[t]={}
an2[t]={}
ph[t]=1 ls[t]=1 le[t]=6 dv2[t]=1 dc[t]=0 an[t]=-1
aph[t]=1 als[t]=1 ale[t]=le[t] adv2[t]=1 adc[t]=0 addr[t]=1
for s=1,STEPS do
tr[t][s]=false no[t][s]=1 oc[t][s]=ODR du[t][s]=0 prb[t][s]=4
rdv[t][s]=1 rsl[t][s]=1
an2[t][s]=-1
end
end
tr[1][1]=true oc[1][1]=5
ms=false tr2=false cp=0 pt={} PB=8 sp=6 cpls=false cbt=0
thk=nil tht=0 sch=nil scfc=0 cpt=nil clrt=nil fsh=nil fld=nil fsa=nil psi=false pclh=false
nom={}
for t=1,4 do
local tc=t
nom[t]=metro.init(function()
if an[tc]>=0 then midi_note_off(an[tc],0,TCH[tc]) an[tc]=-1 end
nom[tc]:stop()
end,0.1,1)
end
rsc={0,0,0,0}
ram={}
for t=1,4 do
local tc=t
ram[t]=metro.init(function()
local s=ph[tc]
rsc[tc]=rsc[tc]+1
if rsc[tc]>(rdv[tc][s] or 1) then ram[tc]:stop() return end
if rget(tc,s,rsc[tc]) then
local ns=tclk[tc] and nph[tc] or s
son(tc,ns) if tclk[tc] then advnph(tc) end
end
end,.1)
end
icl=metro.init(function() if tka then tka() end end,.125)
icl:stop()
phl=nil pht=nil HT=0.8 kvm=0 shld=false scph=nil
cued=nil cclk=16 ccc=0 cdc=0 clt=1 cman=false pth=false pflash=0 pflx=0 fldfl=false fsafl=false
rchy=nil rchx=nil
shm=metro.init(function()
if thk then
tadj(thk)
elseif rchy~=nil and rchx~=nil then
if rchy==1 then
for s=1,STEPS do
local nd=rdv[at][s] or 1
for i=1,nd do rset(at,s,i,true) end
end
elseif rchy==7 then
rdv[at][rchx]=1 rsl[at][rchx]=1
end
rchy=nil rchx=nil shm:stop() rd()
elseif clrt then
local t=clrt
if vm==1 or vm==11 then
for s=1,STEPS do tr[t][s]=false end
elseif vm==2 or vm==12 then
for s=1,STEPS do no[t][s]=1 tr[t][s]=false end
elseif vm==3 then
for s=1,STEPS do oc[t][s]=ODR end go2[t]=3
elseif vm==4 then
for s=1,STEPS do du[t][s]=0 end gdu[t]=16
end
clrt=nil shm:stop() rd()
gl(t,8,BF) gr()
elseif phl and vm==7 then
local ok=pcall(svp,phl)
if ok then ap=phl pflx=phl pflash=8 fsh={get_time(),phl} end
phl=nil
shm:stop() rd()
elseif fld or fsa then
if fld then fldfl=true gl(1,7,BF) gr() end
if fsa then fsafl=true gl(3,7,BF) gr() end
shm:stop()
else shm:stop() end
end,0.4)
shm:stop()
grid_led_all(F)
tr2=false
rd()
