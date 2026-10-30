from pathlib import Path
import math
from reportlab.pdfgen import canvas
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.lib.colors import HexColor, white

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / 'output/pdf/four-lock-controller.pdf'
OUT.parent.mkdir(parents=True, exist_ok=True)
pdfmetrics.registerFont(TTFont('CN', '/System/Library/Fonts/Supplemental/Arial Unicode.ttf'))
W, H = 1190.55, 841.89  # A3 landscape
c = canvas.Canvas(str(OUT), pagesize=(W, H))
c.setTitle('四柜失物招领系统 - 电路与接线设计 V1')
c.setAuthor('Circuit design for Raspberry Pi 4B / XG4031-A')
INK='#18283D'; MUTED='#536478'; GRID='#CFD8E3'; BLUE='#235AC6'; RED='#C53D3D'
GREEN='#16765B'; PURPLE='#784CB6'; LIGHT='#F3F6FA'; ORANGE='#A95C0B'

def txt(x,y,s,size=12,color=INK):
    c.setFont('CN',size); c.setFillColor(HexColor(color)); c.drawString(x,H-y,s)
def lines(x,y,ss,size=12,step=21,color=INK):
    for i,s in enumerate(ss): txt(x,y+i*step,s,size,color)
def rect(x,y,w,h,fill=white,stroke=GRID,r=6):
    c.setFillColor(HexColor(fill) if isinstance(fill,str) else fill)
    c.setStrokeColor(HexColor(stroke)); c.setLineWidth(1)
    c.roundRect(x,H-y-h,w,h,r,fill=1,stroke=1)
def wire(pts,color=INK,width=1.6,dash=None):
    c.setStrokeColor(HexColor(color)); c.setLineWidth(width)
    c.setDash(dash or [])
    p=c.beginPath(); p.moveTo(pts[0][0],H-pts[0][1])
    for x,y in pts[1:]: p.lineTo(x,H-y)
    c.drawPath(p); c.setDash([])
def dot(x,y,color=INK,r=2.8):
    c.setFillColor(HexColor(color));c.circle(x,H-y,r,fill=1,stroke=0)
def arrow(x1,y1,x2,y2,color=BLUE,width=1.7):
    wire([(x1,y1),(x2,y2)],color,width)
    a=math.atan2(y2-y1,x2-x1); l=7
    wire([(x2-l*math.cos(a-.45),y2-l*math.sin(a-.45)),(x2,y2),(x2-l*math.cos(a+.45),y2-l*math.sin(a+.45))],color,width)
def crossing_bridge(x,y,color=RED):
    # White under-stroke separates the overpassing signal from the power trunk.
    for col,lw in [('white',6),(color,2)]:
        c.setStrokeColor(white if col=='white' else HexColor(col)); c.setLineWidth(lw)
        p=c.beginPath();p.moveTo(x-8,H-y)
        p.curveTo(x-8,H-y+12,x+8,H-y+12,x+8,H-y)
        c.drawPath(p)
def gnd(x,y,label=True):
    wire([(x,y),(x,y+10)],MUTED)
    for dy,half in [(10,12),(15,8),(20,4)]: wire([(x-half,y+dy),(x+half,y+dy)],MUTED)
    if label:txt(x-15,y+36,'GND',10,MUTED)
def resistor(x1,y1,x2,y2,label=None,color=INK):
    if y1==y2:
        mid=(x1+x2)/2; wire([(x1,y1),(mid-15,y1)],color)
        rect(mid-15,y1-5,30,10,white,color,0);wire([(mid+15,y1),(x2,y2)],color)
        if label:txt(mid-26,y1-13,label,11,color)
    else:
        mid=(y1+y2)/2;wire([(x1,y1),(x1,mid-15)],color)
        rect(x1-5,mid-15,10,30,white,color,0);wire([(x1,mid+15),(x2,y2)],color)
        if label:txt(x1+12,mid+3,label,11,color)
def capacitor(x1,y1,x2,y2,label=None):
    if y1==y2:
        mid=(x1+x2)/2;wire([(x1,y1),(mid-4,y1)]);wire([(mid+4,y1),(x2,y2)])
        wire([(mid-4,y1-13),(mid-4,y1+13)]);wire([(mid+4,y1-13),(mid+4,y1+13)])
        if label:txt(mid-35,y1-22,label,11)
    else:
        mid=(y1+y2)/2;wire([(x1,y1),(x1,mid-4)]);wire([(x1,mid+4),(x2,y2)])
        wire([(x1-13,mid-4),(x1+13,mid-4)]);wire([(x1-13,mid+4),(x1+13,mid+4)])
        if label:txt(x1+18,mid+3,label,11)
def diode(x,y,label='1N5408'):
    # cathode on left; current in flyback runs right-to-left
    wire([(x-32,y),(x-7,y)],GREEN)
    wire([(x+9,y),(x+32,y)],GREEN)
    wire([(x-7,y-10),(x-7,y+10)],GREEN,2)
    wire([(x-7,y),(x+9,y-10),(x+9,y+10),(x-7,y)],GREEN,1.5)
    if label:txt(x-32,y-17,label,10,GREEN)
def heading(num,title,sub):
    c.setFillColor(white); c.rect(0,0,W,H,fill=1,stroke=0)
    txt(34,42,title,25)
    txt(35,69,sub,11.5,MUTED)
    wire([(35,85),(1155,85)],GRID,1)
    wire([(35,805),(1155,805)],GRID,1)
    txt(35,825,'XG4031-A 5V / 华控5V继电器 / Raspberry Pi 4B   ·   V1   ·   2026-10-20',10,MUTED)
    txt(895,825,f'设计待实物验证    |    {num} / 5',10,MUTED)
def table(x,y,widths,headers,rows,rh=32,size=12):
    total=sum(widths);rect(x,y,total,rh,'#E7EEF7',GRID,0)
    yy=y
    for rowi,row in enumerate([headers]+rows):
        if rowi:
            yy=y+rowi*rh
            rect(x,yy,total,rh,white if rowi%2 else '#F7F9FC',GRID,0)
        xx=x
        for w,s in zip(widths,row):
            txt(xx+9,yy+rh/2+4,str(s),size,INK)
            xx+=w
def end(): c.showPage()

# 1: Integrated four-channel diagram
heading(1,'四柜失物招领系统 · 总电路接线图','圆点表示相连；跨线拱桥表示不相连；同名网络必须相连。控制与负载分电源、单点共地。单路详见第2–3页。')
rect(35,104,230,70,'#EDF3FF',BLUE)
lines(49,128,['P1  树莓派专用电源','5.1V / 3A → USB-C'],14,23,BLUE)
rect(320,104,260,70,'#FFF4F1',RED)
lines(335,128,['P2  锁与继电器电源','稳压5V / 10A，封闭式低压输出'],13,23,RED)
wire([(580,130),(608,130)],RED,2)
rect(608,114,94,32,'#FFF4F1',RED,2);txt(623,135,'F0  10A',12,RED)
wire([(702,130),(725,130)],RED,2)
rect(725,114,112,32,'#FFF4F1',RED,2);txt(739,135,'S0  检修开关',11,RED)
wire([(837,130),(856,130),(856,635)],RED,2.3)
txt(863,150,'+5_LOCK',11,RED)
wire([(856,167),(980,167)],RED,1.8);dot(856,167,RED)
txt(985,171,'C0 1000µF + 100nF → GND',10,RED)
wire([(856,193),(950,193)],RED,1.8);dot(856,193,RED)
txt(958,197,'F5 1A → +5_RELAY',11,RED)
txt(320,201,'P2负极 → GND_STAR；四锁回流分别接星形地',11,MUTED)
txt(320,221,'所有K的DC+接+5_RELAY，DC−接GND；局部加100µF + 100nF',11,MUTED)
rect(35,249,230,387,'#EDF3FF',BLUE)
txt(51,279,'Raspberry Pi 4B',20,BLUE)
wire([(150,174),(150,249)],BLUE,2);txt(160,216,'USB-C',11,BLUE)
txt(51,305,'命令输出 / BCM编号',12,MUTED)
commands=[(17,11,'U1A'),(27,13,'U1B'),(22,15,'U2A'),(23,16,'U2B')]
ys=[328,413,498,583]
wire([(1128,274),(1128,658)],MUTED,2)
txt(1060,270,'GND_STAR',11,MUTED)
for i,(cy,(gp,pp,u)) in enumerate(zip(ys,commands),1):
    txt(51,cy+5,f'柜{i}  GPIO{gp} / 针{pp}',13,BLUE)
    arrow(265,cy,315,cy)
    rect(315,cy-30,132,60,'#F1EEFA',PURPLE)
    lines(328,cy-8,[f'{u}  硬件限时','约0.5秒，需实测'],11,22,PURPLE)
    arrow(447,cy,488,cy)
    rect(488,cy-30,117,60,'#EDF6F2',GREEN)
    lines(501,cy-8,[f'Q{i}  NPN驱动','1kΩ + 10kΩ'],11,22,GREEN)
    arrow(605,cy,650,cy)
    rect(650,cy-32,145,64,white,INK)
    txt(661,cy-11,f'K{i}  5V继电器',12)
    txt(661,cy+12,'IN · LOW触发',11)
    txt(755,cy-12,'COM',10,RED);txt(762,cy+22,'NO',10,RED)
    wire([(856,cy-17),(838,cy-17)],RED,2);dot(856,cy-17,RED)
    rect(810,cy-24,28,14,white,RED,0);txt(807,cy-32,f'F{i} 3A',9,RED)
    wire([(810,cy-17),(795,cy-17)],RED,2)
    wire([(795,cy+17),(848,cy+17)],RED,2)
    crossing_bridge(856,cy+17)
    wire([(864,cy+17),(940,cy+17)],RED,2)
    rect(940,cy+1,104,32,'#FFF4F1',RED,3);txt(954,cy+22,f'L{i}  5V / 2A',11,RED)
    txt(912,cy+37,'红',10,RED);txt(1050,cy+37,'黑',10,MUTED)
    wire([(1044,cy+17),(1128,cy+17)],MUTED,2);dot(1128,cy+17,MUTED)
    wire([(917,cy+17),(917,cy-20),(963,cy-20)],GREEN);dot(917,cy+17,RED)
    diode(995,cy-20,f'D{i} 1N5408')
    wire([(1027,cy-20),(1085,cy-20),(1085,cy+17)],GREEN);dot(1085,cy+17,MUTED)
    txt(933,cy-9,'K/色环',8,GREEN)
txt(651,651,'各路NC不接；COM/NO按板上丝印识别',10,MUTED)
txt(49,662,'针1=3.3V → U1/U2与反馈上拉；针6=GND → 星形地',11,BLUE)
rect(35,686,630,101,'#F1EEFA',PURPLE)
txt(50,710,'四路反馈与总使能',14,PURPLE)
lines(50,734,['GPIO25 / 针22 → ARM → U1/U2全部低有效复位R；10kΩ下拉，启动先禁止。',
    '柜1–4反馈 → GPIO5/6/13/19（针29/31/33/35），各有3.3V上拉和RC滤波。',
    '仅接已确认无源的蓝白触点；否则换独立门磁。详见第3页。'],11,20)
rect(687,686,468,101,'#FFF8E9','#D4A147')
lines(702,711,['通电脉冲开锁；关门靠机械扣锁，不能电动关门。',
    '原锁每次通电≤3秒；软件防重复，硬件限制单次脉冲。',
    '锁电流不经过Pi排针；两路电源正极不相连。',
    '二极管色环接红线；四路分别就近安装。'],12,21)
end()

# 2: Detailed channel schematic
heading(2,'单路控制详图 · 复制4份','展示第1柜；其他柜电路完全相同，按第4页更换GPIO、计时通道和继电器编号。')
rect(35,105,1120,373,'#FBFCFE',GRID)
txt(53,131,'控制信号：3.3V逻辑 → 固定脉冲 → NPN开集电极 → 5V继电器IN',15,BLUE)
txt(53,197,'GPIO17',13,BLUE);txt(53,219,'物理针11',11,BLUE)
wire([(127,207),(260,207)],BLUE)
dot(180,207,BLUE);resistor(180,207,180,286,'10kΩ');gnd(180,286)
rect(260,165,210,170,'#F1EEFA',PURPLE)
lines(278,191,['U1A  CD74HC221E','B(2)  上升沿触发','A(1) → GND','R(3) → ARM','Q(13) 输出约0.5秒'],12,27,PURPLE)
wire([(470,274),(510,274)],BLUE)
resistor(510,274,600,274,'RB1 1kΩ',BLUE)
wire([(600,274),(664,274)],BLUE);dot(620,274,BLUE)
resistor(620,274,620,367,'RBE1 10kΩ');gnd(620,367)
# NPN symbol
c.setStrokeColor(HexColor(GREEN));c.setLineWidth(1.6);c.circle(700,H-274,36,fill=0,stroke=1)
wire([(664,274),(685,274)],GREEN);wire([(685,252),(685,297)],GREEN,2)
wire([(685,262),(716,240),(716,209)],GREEN)
wire([(685,286),(716,309),(716,366)],GREEN)
arrow(696,294,711,306,GREEN);gnd(716,366)
txt(653,261,'B2',10,GREEN);txt(723,239,'C1',10,GREEN);txt(723,333,'E3',10,GREEN)
lines(758,302,['Q1  P2N2222AG','1=C，2=B，3=E','仅切换继电器输入电流'],12,23,GREEN)
wire([(716,209),(907,209)],GREEN)
rect(907,166,215,190,white,INK)
lines(924,190,['K1  华控5V模块','IN1 ← Q1集电极','DC+ ← +5_RELAY','DC− ← GND','跳帽：LOW—COM','输出：COM / NO / NC'],12,28)
txt(54,426,'ARM = GPIO25 / 物理针22；10kΩ下拉。ARM=0时四路复位，Q输出低。',13,PURPLE)
txt(54,452,'注意：NPN不是直接驱动2A锁线圈；锁电流只流经继电器触点。',12,MUTED)
rect(35,498,1120,285,'#FBFCFE',GRID)
txt(53,527,'负载回路：外置5V供电 + 常开触点 + 就地续流保护',15,RED)
txt(55,591,'+5_LOCK',13,RED);wire([(135,587),(180,587)],RED,2)
rect(180,572,90,30,white,RED,1);txt(199,592,'F1 3A',12,RED)
wire([(270,587),(349,587)],RED,2);dot(349,587,RED)
wire([(349,587),(400,562)],RED,2);dot(430,587,RED)
txt(325,615,'COM',11);txt(423,615,'NO',11)
txt(327,550,'K1 常开触点',12)
wire([(430,587),(610,587)],RED,2)
rect(610,568,190,40,'#FFF4F1',RED);txt(633,594,'L1  电磁锁 5V / 2A',13,RED)
wire([(800,587),(1040,587),(1040,706)],MUTED,2);gnd(1040,706)
txt(566,610,'红线 +',11,RED);txt(815,610,'黑线 −',11,MUTED)
dot(550,587,RED);dot(875,587,MUTED)
wire([(550,587),(550,667),(673,667)],GREEN)
diode(705,667,'D1  1N5408 / 3A')
wire([(737,667),(875,667),(875,587)],GREEN)
txt(570,690,'K 阴极 / 带色环',12,GREEN);txt(755,690,'A 阳极',12,GREEN)
txt(55,741,'D1反向并联于锁两端，尽量靠近锁；已有内置抑制器件时先核对厂家要求。',12)
txt(55,765,'NC留空；保险丝保护短路，不会防止正常2A电流下的线圈过热。',12,MUTED)
end()

# 3: Timing and feedback
heading(3,'限时器与反馈接口 · 具体引脚','U1/U2使用TI CD74HC221E（HC、PDIP16）；用芯片引脚编号接线，不凭图形位置猜封装方向。')
rect(35,106,565,387,'#F9F7FD',PURPLE)
txt(52,135,'每片双通道；两片共四路',17,PURPLE)
table(50,151,[151,90,90,195],['功能','A半部','B半部','连接'],[
    ['A输入','1','9','GND'],['B输入','2','10','命令GPIO + 10k下拉'],
    ['低有效复位 R','3','11','ARM / GPIO25'],['Q正脉冲输出','13','5','经1kΩ到NPN基极'],
    ['反相 /Q','4','12','不接'],['Cx','14','6','定时电容一端'],
    ['RxCx','15','7','R与C连接点'],['电源 VCC / GND','16','8','3.3V / GND']],rh=32,size=11)
txt(52,467,'每片16–8脚旁100nF；控制板3.3V再并4.7µF。',11)
rect(620,106,535,387,'#FBFCFE',GRID)
txt(638,135,'每通道RC定时接法',17,PURPLE)
txt(647,185,'3.3V',13,BLUE)
wire([(702,181),(744,181)],BLUE)
resistor(744,181,867,181,'RT 330kΩ / 1%')
wire([(867,181),(941,181),(941,249)],PURPLE);dot(941,249,PURPLE)
wire([(941,249),(1042,249)],PURPLE)
txt(982,236,'RxCx',12,PURPLE);txt(1017,268,'15 / 7脚',11,PURPLE)
capacitor(941,249,941,342)
txt(752,299,'CT 2.2µF 薄膜',12);txt(769,322,'低漏电 / 5%或10%',11,MUTED)
wire([(941,342),(1042,342)],PURPLE)
txt(984,329,'Cx',12,PURPLE);txt(1017,362,'14 / 6脚',11,PURPLE)
lines(638,400,['Cx不接地。R接3.3V，C跨接两个定时脚。',
    '3.3V下预计约0.5秒；0.7RC公式的条件是4.5V。',
    '装配后测量各路，目标0.4–1.0秒；不得超过3秒。',
    '新触发不能延长当前脉冲；持续重复命令仍需软件阻止。'],11,21)
rect(35,511,1120,272,'#F3F9F6',GREEN)
txt(52,540,'锁/门反馈：每柜一组，仅适用于无源干接点',17,GREEN)
txt(60,602,'3.3V',13,BLUE);wire([(113,598),(155,598)],BLUE)
resistor(155,598,270,598,'RPU 10kΩ')
wire([(270,598),(470,598)],GREEN);dot(360,598,GREEN)
resistor(470,598,610,598,'RS 1kΩ')
wire([(610,598),(780,598)],GREEN);dot(690,598,GREEN)
arrow(780,598,912,598,GREEN);txt(920,603,'对应反馈GPIO',13,GREEN)
wire([(360,598),(360,640)],GREEN);dot(360,640,GREEN)
wire([(360,640),(386,666)],GREEN);dot(360,681,GREEN)
wire([(360,681),(360,699)],GREEN);gnd(360,699)
txt(167,653,'Si 已确认无源触点',12,GREEN);txt(167,674,'或独立门磁开关',12,GREEN)
capacitor(690,598,690,699,'CF 100nF');gnd(690,699)
lines(52,750,['蓝白线的电气类型未在原锁说明书中给出：确认隔离、无源后才能使用；不明时改用独立无源门磁。',
    '接点闭合读0，断开读1；状态含义现场标定，去抖50ms。门磁只能确认门位置，不能确认已扣锁或柜内有物。'],11,21)
end()

# 4: Pin mapping, BOM and routing
heading(4,'接线表与物料清单','优先按本页逐线贴标签；所有GPIO为BCM编号，“针”是Pi的40针排针物理编号。')
table(35,108,[85,185,130,145,205,370],['柜号','命令输出','计时通道','驱动与继电器','反馈输入','负载接线'],[
    ['1','GPIO17 / 针11','U1A','Q1 → K1.IN','GPIO5 / 针29','F1 → K1.COM；K1.NO → L1红'],
    ['2','GPIO27 / 针13','U1B','Q2 → K2.IN','GPIO6 / 针31','F2 → K2.COM；K2.NO → L2红'],
    ['3','GPIO22 / 针15','U2A','Q3 → K3.IN','GPIO13 / 针33','F3 → K3.COM；K3.NO → L3红'],
    ['4','GPIO23 / 针16','U2B','Q4 → K4.IN','GPIO19 / 针35','F4 → K4.COM；K4.NO → L4红'],
],rh=36,size=12)
rect(35,301,1120,63,'#EDF3FF',BLUE)
lines(50,326,['总使能：GPIO25 / 针22 → U1与U2的3、11脚；R_ARM=10kΩ下拉至GND。',
    '3.3V：针1 → 计时芯片与反馈上拉；GND：针6 → GND_STAR；Pi针2/4的5V不接锁电源。'],12,23)
table(35,383,[260,65,235],['器件','数量','规格'],[
    ['Pi 4B + 存储卡','1套','USB-C 5.1V/3A独立电源'],
    ['锁电源P2','1','5V/10A，封闭式，过流保护'],
    ['XG4031-A电磁锁','4','5V/2A，通电≤3秒'],
    ['华控5V继电器模块','4路','四单路或同系列四路板'],
    ['CD74HC221E + 16脚座','各2','HC型，不用HCT型'],
    ['P2N2222AG / 1N5408','各4','NPN输入驱动 / 锁续流'],
    ['330kΩ / 2.2µF薄膜','各4','定时R 1%；C 5%或10%'],
    ['1kΩ / 10kΩ电阻','8 / 13','基极、输入、反馈及ARM'],
],rh=32,size=11)
table(615,383,[260,65,215],['器件','数量','规格'],[
    ['100nF电容','8','2IC + 4反馈 + 2电源'],
    ['4.7µF电容','1','控制板3.3V去耦'],
    ['1000µF / 100µF电解','各1','均10V，正极接+5V'],
    ['保险丝与座','6套','10A×1、3A×4、1A×1'],
    ['检修开关S0','1','至少12VDC/15A'],
    ['独立无源门磁','0或4','原锁反馈不明时使用'],
    ['配电端子 / 支路端子','按需','额定至少15A / 5A'],
    ['主线 / 短距离支路线','按需','建议AWG16 / AWG20'],
],rh=32,size=11)
rect(35,692,1120,91,'#FFF8E9','#D4A147')
lines(50,717,['功率预算：4 × 2A + 继电器与输入约0.2A ≈ 8.2A；选5V/10A。软件日常串行开锁，仍保留四路峰值供电能力。',
    'GND_STAR：锁黑线、模块DC−、控制板GND、Pi针6分别回到配电负极；锁电流不得流经Pi排针或面包板。',
    '保险丝曲线、导线长度、端子和温升需配套校核；约1米支路可从AWG20起选，柜体更大时重新核算压降。'],12,24)
end()

# 5: behavior and test
heading(5,'控制流程、验证与资料依据','本次交付为接线设计。未声称完成硬件搭建、电气仿真、现场测试或产品安全认证。')
rect(35,106,1120,101,'#EDF3FF',BLUE)
txt(50,134,'从领取请求到柜门确认',17,BLUE)
stages=[('身份/凭证校验',40),('绑定柜号',270),('20ms命令脉冲',490),('反馈确认',710),('合门与记录',930)]
for idx,(label,x) in enumerate(stages):
    rect(x+10,151,178,35,white,BLUE,4);txt(x+24,174,label,13,BLUE)
    if idx<4:arrow(x+188,168,stages[idx+1][1]+10,168)
rect(35,226,545,278,'#F9F7FD',PURPLE)
txt(52,255,'启动与命令规则',17,PURPLE)
lines(52,284,['1. ARM置0，四个命令GPIO全部初始化为0。',
    '2. 确认反馈后ARM置1，等待至少1ms，再允许开锁。',
    '3. 指定GPIO高20ms后拉低；硬件产生约0.5秒输出。',
    '4. 请求去重；开锁失败不自动连续重试。',
    '5. 退出时先ARM置0；一个时刻只处理一个开柜事务。',
    '6. 未取得厂家占空比前，调试暂留至少30秒冷却。',
    '7. 存物/取物结果绑定柜号、用户、凭证和操作时间。',
    '8. 门关闭不代表柜内有物；物品检测需额外传感器。'],12,27)
rect(600,226,555,278,'#F3F9F6',GREEN)
txt(617,255,'接锁前后必须完成的验收',17,GREEN)
lines(617,284,['1. 断电核对正负极、COM/NO、二极管和芯片朝向。',
    '2. 接好驱动和继电器，测Q/IN电压与0.4–1.0秒脉冲。',
    '3. 命令保持高5秒，只允许一个短脉冲；验证ARM复位。',
    '4. 上电、重启、复位及B=0时释放ARM，应无开锁脉冲。',
    '5. 单锁验证弹开、机械合锁、压降与反馈极性。',
    '6. 四路逐一测试；受控同时触发时检查电源与Pi稳定性。',
    '7. 验证断网、退出与重复请求，留下测试记录。',
    '8. 保留锁的机械应急拉杆检修通道。'],12,27)
rect(35,521,1120,77,'#FFF8E9','#D4A147')
lines(50,546,['保护范围：单稳态限制一次触发，不能阻止无限重复触发；也不能切断已焊死的继电器触点或短路的驱动。',
    '发现持续通电用S0切断锁电源。保险丝只保护过流，不能替代限时器；正式运行前确认锁的允许频次与温升。'],12,26)
txt(35,629,'资料依据与图纸边界',16)
sources=[
    ('[1] XG4031-A：用户提供规格书，5V/2A、≤3秒、通电脱扣/手动上锁。',None),
    ('[2] 华控光耦隔离继电器手册：5V输入、LOW跳帽与COM/NO。','https://huakongdainzi.oss-cn-shenzhen.aliyuncs.com/产品资料/使用手册/光耦隔离继电器使用手册.pdf'),
    ('[3] Raspberry Pi官方硬件资料：GPIO 3.3V、Pi4 USB-C供电。','https://www.raspberrypi.com/documentation/computers/raspberry-pi.html'),
    ('[4] TI CD74HC221：HC 2–6V、双单稳态、引脚及RC。','https://www.ti.com/lit/ds/symlink/cd74hc221.pdf'),
    ('[5] onsemi P2N2222A；Vishay 1N540x：驱动管与续流二极管参数。','https://www.onsemi.com/pdf/datasheet/p2n2222a-d.pdf'),
    ('[6] OMRON：感性负载反电势与续流保护；二极管会影响释放时间。','https://www.ia.omron.com/support/faq/answer/18/faq02129/'),
]
for i,(s,url) in enumerate(sources):
    y=653+i*22;txt(35,y,s,11,MUTED)
    if url:c.linkURL(url,(35,H-y-3,1100,H-y+13),relative=0,thickness=0)
txt(35,794,'完整解释、精确BOM与现场检查步骤见随附 design.md；总图中的同名网络代表电气相连。',10,MUTED)
end()
c.save()
print(OUT)
