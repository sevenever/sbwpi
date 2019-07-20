#!/usr/bin/python

import json
import subprocess

from flask import Flask, redirect
from flask import request
from flask import render_template
app = Flask(__name__)

psks=json.load(open('psks.json'))

@app.route('/', methods=['POST','GET'])
def index():
	p=subprocess.Popen('ping -4 -c 1 www.baidu.com', shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
	stdout, stderr = p.communicate()
	connected = p.wait() == 0
	if not connected:
		p=subprocess.Popen('echo ====================================== ;'
				   'echo ip link:;ip link show wlan1 2>&1;'
				   'echo ====================================== ;'
				   'echo ip addr show wlan1:; ip addr show wlan1 2>&1;'
				   'echo ====================================== ;'
				   'echo ping -4 -c 1 114.114.114.114:; ping -4 -c 1 114.114.114.114 2>&1;'
				   'echo ====================================== ;'
				   'echo dig www.baidu.com :; dig www.baidu.com 2>&1',
				 shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
		stdout, stderr = p.communicate()
		wlan1 = stdout
	else:
		wlan1 = ""
		
	p=subprocess.Popen('iwlist wlan0 scanning |grep ESSID |cut -d : -f 2|cut -d \\" -f 2', shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
	stdout, stderr =  p.communicate()
	scans=[x for x in str(stdout).split('\n') if len(x)>0]
	
	return render_template('index.html', 
				connected=connected,
				wlan1=wlan1,
				psks=psks,
				scans=scans,
				conf=open('/etc/wpa_supplicant/wpa_supplicant-wlan1.conf').read())

@app.route('/add', methods=['POST'])
def add():
	ssid=request.form['ssid']
	psk=request.form['psk']
	psks.append({'ssid':ssid,'psk':psk})
	save()
	return redirect('/', 307)

@app.route('/apply', methods=['POST'])
def apply():
	ssid=request.form['ssid']
	psk=request.form['psk']
	with open('/etc/wpa_supplicant/wpa_supplicant-wlan1.conf','wb') as f:
		f.write('ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev\n')
		f.write('update_config=1\n')
		f.write('\n')
		f.write('network={\n')
		f.write('	ssid="%s"\n' % ssid)
		f.write('	psk="%s"\n' % psk)
		f.write('}\n')
	p=subprocess.Popen('ifdown wlan1;sleep 3;ifup wlan1;sleep 5;', shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
	stdout, stderr = p.communicate()
	connected = p.wait() == 0

	return redirect('/', 307)

@app.route('/del', methods=['POST'])
def delete():
	ssid=request.form['ssid']
	for psk in psks:
		if ssid == psk['ssid']:
			psks.remove(psk)
	save()
	return redirect('/', 307)

def save():
	json.dump(psks, open('psks.json','wb'))
	
			
