#!/usr/bin/env python3
"""
Wi-Fi Mode Manager for Raspberry Pi
Supports:
1. NetworkManager (nmcli) - Recommended
2. Legacy (wpa_supplicant/dhcpcd) - Fallback for Tethering only
"""

import os
import subprocess
import json
import logging
import time
import shutil
import binascii
import hashlib

logger = logging.getLogger(__name__)

# 設定ファイルパス
SETTINGS_FILE = '/home/pi/camera_settings.json'
WPA_SUPPLICANT_CONF = '/etc/wpa_supplicant/wpa_supplicant.conf'

# APモード時の想定固定IP（Raspberry Pi OSのデフォルト範囲: 192.168.4.1）
AP_IP = '192.168.4.1'

# 環境変数または設定ファイルからデフォルト値を取得（ハードコード回避）
def _get_default_ap_ssid():
    """デフォルトAP SSIDを取得（環境変数 AP_SSID で上書き可能）"""
    return os.environ.get('AP_SSID', 'PiCamera')

def _get_default_ap_password():
    """デフォルトAPパスワードを取得（環境変数 AP_PASSWORD で上書き可能）"""
    return os.environ.get('AP_PASSWORD', 'picamera123')

def _get_primary_ip():
    """Return primary IP address string if available"""
    try:
        iface = _detect_wifi_interface()
        ips = _get_ipv4_addrs_for_interface(iface)
        if ips:
            return ips[0]
    except Exception:
        pass
    try:
        result = subprocess.run(
            ['hostname', '-I'],
            capture_output=True, text=True
        )
        ips = result.stdout.strip().split()
        for ip in ips:
            if ip and not ip.startswith('127.'):
                return ip
    except Exception:
        pass
    return None

def _get_ipv4_addrs_for_interface(iface):
    try:
        result = subprocess.run(
            ['ip', '-4', 'addr', 'show', 'dev', iface],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0 or not result.stdout:
            return []

        ips = []
        for line in result.stdout.splitlines():
            line = line.strip()
            if not line.startswith('inet '):
                continue
            parts = line.split()
            if len(parts) < 2:
                continue
            ip = parts[1].split('/', 1)[0].strip()
            if ip and not ip.startswith('127.'):
                ips.append(ip)
        return ips
    except Exception:
        return []

def has_nmcli():
    """Check if nmcli is available"""
    nmcli_cmd = _resolve_executable('nmcli')
    return os.path.isabs(nmcli_cmd) and os.path.exists(nmcli_cmd)

def _resolve_executable(name, extra_candidates=None):
    path = shutil.which(name)
    if path:
        return path

    candidates = list(extra_candidates or [])
    candidates.extend([
        f'/sbin/{name}',
        f'/usr/sbin/{name}',
        f'/usr/bin/{name}',
        f'/bin/{name}',
    ])

    for candidate in candidates:
        if os.path.exists(candidate):
            return candidate

    return name

def _is_networkmanager_running():
    if not has_nmcli():
        return False

    nmcli_cmd = _resolve_executable('nmcli')

    try:
        res = _run(['systemctl', 'is-active', 'NetworkManager'], timeout=10)
        if res['stdout'].strip() == 'active':
            return True
    except Exception:
        pass

    try:
        res = _run([nmcli_cmd, 'general', 'status'], timeout=10)
        if res['returncode'] == 0 and res['stdout']:
            return True
    except Exception:
        pass

    return False

def _ensure_networkmanager_running(timeout=15):
    if not has_nmcli():
        return False, 'nmcli (NetworkManager) が見つかりません'

    if _is_networkmanager_running():
        return True, None

    start_res = _run(['sudo', '-n', 'systemctl', 'start', 'NetworkManager'], timeout=20)
    if start_res['returncode'] != 0:
        return False, f"NetworkManager start failed: {start_res['stderr'] or start_res['stdout']}"

    start_time = time.time()
    while time.time() - start_time < timeout:
        if _is_networkmanager_running():
            return True, None
        time.sleep(1)

    return False, 'NetworkManager が起動しませんでした'

def _detect_wifi_interface():
    try:
        iw_cmd = _resolve_executable('iw')
        res = _run([iw_cmd, 'dev'])
        if res['returncode'] == 0 and res['stdout']:
            for line in res['stdout'].splitlines():
                line = line.strip()
                if line.startswith('Interface '):
                    return line.split('Interface ', 1)[1].strip()
    except Exception:
        pass

    for candidate in ('wlan0', 'wlan1'):
        if os.path.exists(f'/sys/class/net/{candidate}'):
            return candidate
    return 'wlan0'

def _detect_wpa_ctrl_dir():
    for path in ('/run/wpa_supplicant', '/var/run/wpa_supplicant'):
        if os.path.isdir(path):
            return path
    return '/run/wpa_supplicant'

def _restart_wpa_supplicant_services(iface):
    """Restart wpa_supplicant in a way that matches the systemd unit layout.

    On Raspberry Pi OS, `wpa_supplicant@<iface>` may require
    `/etc/wpa_supplicant/wpa_supplicant-<iface>.conf`. If that file doesn't
    exist, restarting the templated unit fails and tethering won't come up.
    """
    iface = iface or _detect_wifi_interface()
    per_iface_conf = f'/etc/wpa_supplicant/wpa_supplicant-{iface}.conf'

    if not os.path.exists(per_iface_conf):
        _run(['sudo', '-n', 'cp', '-f', WPA_SUPPLICANT_CONF, per_iface_conf])
        _run(['sudo', '-n', 'chmod', '600', per_iface_conf])

    ctrl_dir = _detect_wpa_ctrl_dir()
    sock_path = os.path.join(ctrl_dir, iface)

    _run(['sudo', '-n', 'systemctl', 'stop', f'wpa_supplicant@{iface}'])
    _run(['sudo', '-n', 'systemctl', 'stop', 'wpa_supplicant'])
    _run(['sudo', '-n', 'rm', '-f', sock_path])

    if os.path.exists(per_iface_conf):
        res = _run(['sudo', '-n', 'systemctl', 'restart', f'wpa_supplicant@{iface}'])
        if res['returncode'] == 0:
            return res
        logger.warning(
            f"wpa_supplicant@{iface} restart failed (fallback to wpa_supplicant): "
            f"{res['stderr'] or res['stdout']}"
        )

    return _run(['sudo', '-n', 'systemctl', 'restart', 'wpa_supplicant'])

def _ensure_per_iface_wpa_conf(iface):
    iface = iface or _detect_wifi_interface()
    per_iface_conf = f'/etc/wpa_supplicant/wpa_supplicant-{iface}.conf'
    if os.path.exists(per_iface_conf):
        return True

    cp_res = _run(['sudo', '-n', 'cp', '-f', WPA_SUPPLICANT_CONF, per_iface_conf])
    if cp_res['returncode'] != 0:
        logger.warning(f"Failed to create per-iface wpa conf: {cp_res['stderr'] or cp_res['stdout']}")
        return False
    _run(['sudo', '-n', 'chmod', '600', per_iface_conf])
    return True

def _ensure_wpa_supplicant_running(iface, ctrl_dir):
    sock_path = os.path.join(ctrl_dir, iface)
    if os.path.exists(sock_path):
        return True

    _run(['sudo', '-n', 'systemctl', 'stop', 'hostapd'])
    _run(['sudo', '-n', 'systemctl', 'stop', 'dnsmasq'])
    _run(['sudo', '-n', 'ip', 'link', 'set', iface, 'down'])
    time.sleep(1)
    _run(['sudo', '-n', 'ip', 'link', 'set', iface, 'up'])
    time.sleep(1)

    per_iface_conf = f'/etc/wpa_supplicant/wpa_supplicant-{iface}.conf'
    if os.path.exists(per_iface_conf):
        _run(['sudo', '-n', 'systemctl', 'start', f'wpa_supplicant@{iface}'])
        time.sleep(2)
        if os.path.exists(sock_path):
            return True

    _run(['sudo', '-n', 'systemctl', 'start', 'wpa_supplicant'])
    time.sleep(2)
    if os.path.exists(sock_path):
        return True

    _run([
        'sudo', '-n', 'wpa_supplicant',
        '-B',
        '-i', iface,
        '-c', WPA_SUPPLICANT_CONF,
        '-C', ctrl_dir,
    ])
    time.sleep(2)
    return os.path.exists(sock_path)

def _unsafe_shell_chars_present(value):
    if value is None:
        return False
    return any(ch in value for ch in ('\n', '\r', '\x00'))

def _read_existing_country():
    try:
        res = _run(['sudo', '-n', 'cat', WPA_SUPPLICANT_CONF])
        if res['returncode'] != 0 or not res['stdout']:
            return None
        country = None
        for line in res['stdout'].splitlines():
            line = line.strip()
            if line.startswith('country='):
                country = line.split('=', 1)[1].strip()
        return country
    except Exception:
        pass
    return None

def _run_with_input(cmd, input_text, timeout=20):
    result = subprocess.run(
        cmd,
        input=input_text,
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    return {
        'returncode': result.returncode,
        'stdout': (result.stdout or '').strip(),
        'stderr': (result.stderr or '').strip(),
    }

def _validate_wifi_credentials(ssid, psk):
    if not ssid or not psk:
        return False, 'ssid と psk は必須です'
    if _unsafe_shell_chars_present(ssid) or _unsafe_shell_chars_present(psk):
        return False, 'ssid/psk に未対応の文字が含まれています（改行・NULLなど）。'

    ssid_bytes = ssid.encode('utf-8')
    if len(ssid_bytes) == 0 or len(ssid_bytes) > 32:
        return False, 'ssid は 1〜32 byte の範囲で指定してください'

    if len(psk) < 8 or len(psk) > 63:
        return False, 'psk は 8〜63 文字で指定してください'

    return True, None

def _ssid_to_hex(ssid):
    return binascii.hexlify(ssid.encode('utf-8')).decode('ascii')

def _derive_psk_hex(ssid, psk):
    derived = hashlib.pbkdf2_hmac(
        'sha1',
        psk.encode('utf-8'),
        ssid.encode('utf-8'),
        4096,
        32,
    )
    return binascii.hexlify(derived).decode('ascii')

def _write_wpa_supplicant_conf(ssid, psk, restart_services=True):
    valid, message = _validate_wifi_credentials(ssid, psk)
    if not valid:
        return {
            'success': False,
            'message': message,
        }

    country = _read_existing_country()

    ssid_hex = _ssid_to_hex(ssid)
    psk_hex = _derive_psk_hex(ssid, psk)
    network_block = [
        'network={',
        f'    ssid={ssid_hex}',
        f'    psk={psk_hex}',
        '    key_mgmt=WPA-PSK',
        '}',
    ]

    conf_lines = []
    conf_lines.append('ctrl_interface=DIR=/run/wpa_supplicant GROUP=netdev')
    conf_lines.append('update_config=1')
    if country:
        conf_lines.append(f'country={country}')
    conf_lines.extend(network_block)
    conf_text = '\n'.join(conf_lines) + '\n'

    tmp_path = '/tmp/wpa_supplicant.conf.picamera'
    write_res = _run_with_input(['sudo', '-n', 'tee', tmp_path], conf_text)
    if write_res['returncode'] != 0:
        return {
            'success': False,
            'message': f"write wpa_supplicant.conf failed: {write_res['stderr'] or write_res['stdout']}",
        }

    _run(['sudo', '-n', 'mv', tmp_path, WPA_SUPPLICANT_CONF])
    _run(['sudo', '-n', 'chmod', '600', WPA_SUPPLICANT_CONF])

    iface = _detect_wifi_interface()

    per_iface_conf = f'/etc/wpa_supplicant/wpa_supplicant-{iface}.conf'
    tmp_iface_path = f'/tmp/wpa_supplicant-{iface}.conf.picamera'
    write_iface_res = _run_with_input(['sudo', '-n', 'tee', tmp_iface_path], conf_text)
    if write_iface_res['returncode'] == 0:
        _run(['sudo', '-n', 'mv', tmp_iface_path, per_iface_conf])
        _run(['sudo', '-n', 'chmod', '600', per_iface_conf])
    else:
        logger.warning(
            f"write per-iface wpa_supplicant config failed: {write_iface_res['stderr'] or write_iface_res['stdout']}"
        )

    if restart_services:
        _run(['sudo', '-n', 'systemctl', 'stop', 'hostapd'])
        _run(['sudo', '-n', 'systemctl', 'stop', 'dnsmasq'])
        _run(['sudo', '-n', 'systemctl', 'restart', f'wpa_supplicant@{iface}'])
        _run(['sudo', '-n', 'systemctl', 'restart', 'wpa_supplicant'])
        time.sleep(2)
        _run(['sudo', '-n', 'dhcpcd', '-n', iface])

        return {
            'success': True,
            'message': 'wpa_supplicant.conf を更新しました（ファイル書き換えフォールバック）',
            'iface': iface,
            'country': country,
            'psk_derived': True,
        }

    return {
        'success': True,
        'message': 'wpa_supplicant.conf を更新しました（適用はテザリング切替時）',
        'iface': iface,
        'country': country,
        'psk_derived': True,
    }

def _run(cmd, timeout=20):
    result = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    return {
        'returncode': result.returncode,
        'stdout': (result.stdout or '').strip(),
        'stderr': (result.stderr or '').strip(),
    }

def _is_hotspot_active():
    nmcli_cmd = _resolve_executable('nmcli')
    res = _run([nmcli_cmd, '-t', '-f', 'NAME,TYPE', 'connection', 'show', '--active'], timeout=15)
    if res['returncode'] != 0 or not res['stdout']:
        return False

    for line in res['stdout'].splitlines():
        line = line.strip().lower()
        if not line:
            continue
        if line.startswith('hotspot:') and ('wireless' in line or '802-11-wireless' in line):
            return True
    return False

def _wait_for_ap_ready(iface, timeout=35):
    start_time = time.time()
    last_ips = []
    last_hotspot_active = False

    while time.time() - start_time < timeout:
        last_hotspot_active = _is_hotspot_active()
        last_ips = _get_ipv4_addrs_for_interface(iface)

        ap_ip_ready = any(
            ip.startswith('192.168.4.') or ip.startswith('10.42.0.')
            for ip in last_ips
        )
        if last_hotspot_active and ap_ip_ready:
            return True, None

        time.sleep(2)

    return False, f"hotspot_active={last_hotspot_active}, iface_ips={last_ips}"

def _run_wpa_cli(args, iface=None, timeout=20):
    iface = iface or _detect_wifi_interface()
    ctrl_dir = _detect_wpa_ctrl_dir()
    _ensure_wpa_supplicant_running(iface, ctrl_dir)

    wpa_cli_cmd = _resolve_executable('wpa_cli')

    base_cmd = [wpa_cli_cmd, '-p', ctrl_dir, '-i', iface] + list(args)
    res = _run(base_cmd, timeout=timeout)
    if res['returncode'] == 0 and res['stdout'] and 'FAIL' not in res['stdout']:
        return res

    sudo_cmd = ['sudo', '-n'] + base_cmd
    sudo_res = _run(sudo_cmd, timeout=timeout)
    return sudo_res

def _run_wpa_cli_readonly(args, iface=None, timeout=10):
    iface = iface or _detect_wifi_interface()
    ctrl_dir = _detect_wpa_ctrl_dir()

    wpa_cli_cmd = _resolve_executable('wpa_cli')

    base_cmd = [wpa_cli_cmd, '-p', ctrl_dir, '-i', iface] + list(args)
    res = _run(base_cmd, timeout=timeout)
    if res['returncode'] == 0 and res['stdout'] and 'FAIL' not in res['stdout']:
        return res

    sudo_cmd = ['sudo', '-n'] + base_cmd
    return _run(sudo_cmd, timeout=timeout)

def configure_wpa_supplicant(ssid, psk):
    valid, message = _validate_wifi_credentials(ssid, psk)
    if not valid:
        return {'success': False, 'message': message}

    try:
        return _write_wpa_supplicant_conf(ssid, psk, restart_services=False)
    except subprocess.TimeoutExpired:
        return {'success': False, 'message': 'wpa_supplicant update timed out'}
    except Exception as e:
        logger.error(f"Failed to configure wpa_supplicant: {e}")
        return {'success': False, 'message': str(e)}

def check_tethering_connection(timeout=15):
    """
    テザリングモードで実際に接続できているか確認
    Returns: True if connected, False otherwise
    """
    start_time = time.time()
    iface = _detect_wifi_interface()
    
    while time.time() - start_time < timeout:
        try:
            status = _run_wpa_cli(['status'], iface=iface, timeout=10)
            if status['returncode'] == 0 and status['stdout']:
                fields = {}
                for line in status['stdout'].splitlines():
                    if '=' not in line:
                        continue
                    key, value = line.split('=', 1)
                    fields[key.strip()] = value.strip()

                ssid = fields.get('ssid')
                state = fields.get('wpa_state')
                if state == 'COMPLETED' and ssid:
                    logger.info(f"Connected to SSID: {ssid}")

                    ip_candidates = []
                    for ip in _get_ipv4_addrs_for_interface(iface):
                        if not ip or ip.startswith('127.') or ip.startswith('169.254.'):
                            continue
                        if ip.startswith('192.168.4.') or ip.startswith('10.42.0.'):
                            continue
                        ip_candidates.append(ip)

                    if ip_candidates:
                        ip = ip_candidates[0]
                        logger.info(f"Tethering connection confirmed: IP={ip}")
                        return True
        except Exception as e:
            logger.debug(f"Connection check error: {e}")
        
        time.sleep(2)
    
    logger.warning("Tethering connection check failed")
    return False

def get_current_mode():
    """
    現在のWi-Fiモードを取得する
    Returns: 'ap' or 'tethering'
    """
    if _is_networkmanager_running():
        try:
            nmcli_cmd = _resolve_executable('nmcli')
            result = _run(
                [nmcli_cmd, '-t', '-f', 'NAME,TYPE', 'connection', 'show', '--active'],
                timeout=15,
            )
            if result['returncode'] == 0 and (
                'Hotspot' in result['stdout'] or 'hotspot' in result['stdout'].lower()
            ):
                return 'ap'
        except Exception:
            pass
    
    # Legacy fallback: use IP帯域でAP判定
    ip = _get_primary_ip()
    if ip and (ip.startswith('192.168.4.') or ip.startswith('10.42.0.')):
        return 'ap'
    return 'tethering'

def get_wifi_status():
    """
    Wi-Fiの詳細ステータスを取得
    """
    mode = get_current_mode()
    
    status = {
        'mode': mode,
        'ip_address': None,
        'ip': None,
        'ssid': None
    }
    
    try:
        ip = _get_primary_ip()
        if ip:
            status['ip_address'] = ip
            status['ip'] = ip
        
        if mode == 'ap':
            ap_settings = get_saved_ap_settings()
            status['ssid'] = ap_settings.get('ssid', 'PiCamera')
            status['ip'] = status['ip'] or AP_IP
            status['ip_address'] = status['ip_address'] or AP_IP
        else:
            wpa_status = _run_wpa_cli_readonly(['status'], timeout=10)
            if wpa_status['returncode'] == 0 and wpa_status['stdout']:
                fields = {}
                for line in wpa_status['stdout'].splitlines():
                    if '=' not in line:
                        continue
                    key, value = line.split('=', 1)
                    fields[key.strip()] = value.strip()

                if fields.get('wpa_state') == 'COMPLETED':
                    status['ssid'] = fields.get('ssid')
                
    except Exception as e:
        logger.error(f"Failed to get Wi-Fi status: {e}")
    
    return status

def ensure_ap_persistence(allow_recursive_ap_recovery=True):
    if not has_nmcli():
        return {'success': False, 'message': 'nmcli not available'}

    iface = _detect_wifi_interface()
    nmcli_cmd = _resolve_executable('nmcli')
    iw_cmd = _resolve_executable('iw')
    ctrl_dir = _detect_wpa_ctrl_dir()
    sock_path = os.path.join(ctrl_dir, iface)

    _run(['sudo', '-n', 'systemctl', 'stop', f'wpa_supplicant@{iface}'])
    _run(['sudo', '-n', 'systemctl', 'disable', f'wpa_supplicant@{iface}'])
    _run(['sudo', '-n', 'systemctl', 'stop', 'wpa_supplicant'])
    _run(['sudo', '-n', 'systemctl', 'disable', 'wpa_supplicant'])
    _run(['sudo', '-n', 'rm', '-f', sock_path])
    _run(['sudo', '-n', 'sh', '-c', f'pkill -f "wpa_supplicant.*-i{iface}" || true'])

    _run(['sudo', '-n', 'ip', 'addr', 'flush', 'dev', iface])
    _run(['sudo', '-n', 'ip', 'link', 'set', iface, 'down'])
    time.sleep(1)
    _run(['sudo', '-n', 'ip', 'link', 'set', iface, 'up'])
    time.sleep(1)

    ok, nm_err = _ensure_networkmanager_running()
    if not ok:
        return {'success': False, 'message': nm_err}

    _run(['sudo', '-n', 'systemctl', 'enable', 'NetworkManager'])
    _run(['sudo', '-n', 'systemctl', 'stop', 'dhcpcd'])
    _run(['sudo', '-n', 'systemctl', 'disable', 'dhcpcd'])

    _run(['sudo', '-n', nmcli_cmd, 'networking', 'on'])
    _run(['sudo', '-n', nmcli_cmd, 'radio', 'wifi', 'on'])

    _run(['sudo', '-n', iw_cmd, 'dev', iface, 'set', 'power_save', 'off'])

    saved_ap = get_saved_ap_settings()
    ssid = saved_ap.get('ssid', _get_default_ap_ssid())
    password = saved_ap.get('password', _get_default_ap_password())
    if not password or len(password) < 8:
        password = _get_default_ap_password()

    profile = _run([nmcli_cmd, '-t', '-f', 'NAME', 'connection', 'show', 'Hotspot'], timeout=15)
    if profile['returncode'] != 0:
        create = _run([
            'sudo', '-n', nmcli_cmd, 'device', 'wifi', 'hotspot',
            'ifname', iface,
            'ssid', ssid,
            'password', password,
        ], timeout=40)
        if create['returncode'] != 0:
            return {
                'success': False,
                'message': f"Hotspot profile create failed: {create['stderr'] or create['stdout']}",
            }

    _run(['sudo', '-n', nmcli_cmd, 'connection', 'modify', 'Hotspot', 'connection.autoconnect', 'yes'])
    _run(['sudo', '-n', nmcli_cmd, 'connection', 'modify', 'Hotspot', '802-11-wireless.powersave', '2'])
    _run(['sudo', '-n', nmcli_cmd, 'connection', 'modify', 'Hotspot', '802-11-wireless.band', 'bg'])
    _run(['sudo', '-n', nmcli_cmd, 'connection', 'modify', 'Hotspot', '802-11-wireless.channel', '6'])
    _run(['sudo', '-n', nmcli_cmd, 'connection', 'modify', 'Hotspot', 'ipv4.method', 'shared'])
    _run(['sudo', '-n', nmcli_cmd, 'connection', 'modify', 'Hotspot', 'ipv4.addresses', f'{AP_IP}/24'])

    active = _run([nmcli_cmd, '-t', '-f', 'NAME,TYPE', 'connection', 'show', '--active'], timeout=15)
    if active['returncode'] != 0 or not any('Hotspot:' in line for line in active['stdout'].splitlines()):
        up = _run(['sudo', '-n', nmcli_cmd, 'connection', 'up', 'Hotspot'], timeout=40)
        if up['returncode'] != 0:
            recreate = _run([
                'sudo', '-n', nmcli_cmd, 'device', 'wifi', 'hotspot',
                'ifname', iface,
                'ssid', ssid,
                'password', password,
            ], timeout=40)
            if recreate['returncode'] == 0:
                active = _run([nmcli_cmd, '-t', '-f', 'NAME,TYPE', 'connection', 'show', '--active'], timeout=15)
                if any('Hotspot:' in line for line in active['stdout'].splitlines()):
                    up = {'returncode': 0, 'stdout': 'recreated', 'stderr': ''}

        if up['returncode'] != 0:
            if allow_recursive_ap_recovery:
                saved = get_saved_ap_settings()
                return switch_to_ap_mode(saved.get('ssid'), saved.get('password'))
            return {
                'success': False,
                'message': f"Hotspot connection up failed: {up['stderr'] or up['stdout']}",
            }

    _run(['sudo', '-n', iw_cmd, 'dev', iface, 'set', 'power_save', 'off'])
    ready, ready_err = _wait_for_ap_ready(iface, timeout=30)
    if not ready:
        return {'success': False, 'message': f'AP状態の確認に失敗しました: {ready_err}'}

    ip = _get_primary_ip() or AP_IP
    if not (ip.startswith('192.168.4.') or ip.startswith('10.42.0.')):
        ip = AP_IP

    return {
        'success': True,
        'ip': ip,
        'ip_address': ip,
    }

def switch_to_ap_mode(ssid='PiCamera', password='picamera123'):
    """
    APモードに切り替える
    """
    if not has_nmcli():
        return {
            'success': False, 
            'message': 'APモードへの切り替えには nmcli (NetworkManager) が必要です。現在はサポートされていません。'
        }

    def _fail_with_tethering_recovery(message):
        logger.warning(f"AP switch failed, recovering tethering path: {message}")
        recovery = switch_to_tethering_mode(allow_ap_fallback=False)
        ap_recovery = None

        if recovery.get('success'):
            try:
                _save_wifi_settings('tethering', None, None)
            except Exception as e:
                logger.warning(f"Failed to persist tethering mode after AP recovery: {e}")
        else:
            logger.warning("Tethering recovery failed; trying AP persistence recovery")
            ap_recovery = ensure_ap_persistence(allow_recursive_ap_recovery=False)
            if ap_recovery.get('success'):
                saved_ap = get_saved_ap_settings()
                try:
                    _save_wifi_settings('ap', saved_ap.get('ssid'), saved_ap.get('password'))
                except Exception as e:
                    logger.warning(f"Failed to persist AP mode after AP persistence recovery: {e}")

        ip = (
            recovery.get('ip')
            or recovery.get('ip_address')
            or (ap_recovery or {}).get('ip')
            or (ap_recovery or {}).get('ip_address')
            or _get_primary_ip()
            or AP_IP
        )
        return {
            'success': False,
            'message': message,
            'recovery': recovery,
            'ap_recovery': ap_recovery,
            'ip': ip,
            'ip_address': ip,
        }

    try:
        ssid = ssid or _get_default_ap_ssid()
        password = password or _get_default_ap_password()

        # 引数が空なら保存済み設定を優先
        saved = get_saved_ap_settings()
        ssid = ssid or saved.get('ssid', _get_default_ap_ssid())
        password = password or saved.get('password', _get_default_ap_password())

        logger.info(f"Switching to AP mode with nmcli: SSID={ssid}")

        if len(password) < 8:
            return {'success': False, 'message': 'パスワードは8文字以上必要です'}

        _run(['sudo', '-n', 'systemctl', 'stop', 'hostapd'])
        _run(['sudo', '-n', 'systemctl', 'stop', 'dnsmasq'])
        _run(['sudo', '-n', 'systemctl', 'stop', 'dhcpcd'])
        _run(['sudo', '-n', 'systemctl', 'disable', 'dhcpcd'])
        time.sleep(1)

        iface = _detect_wifi_interface()
        nmcli_cmd = _resolve_executable('nmcli')
        iw_cmd = _resolve_executable('iw')
        ctrl_dir = _detect_wpa_ctrl_dir()
        sock_path = os.path.join(ctrl_dir, iface)

        _run(['sudo', '-n', 'systemctl', 'stop', f'wpa_supplicant@{iface}'])
        _run(['sudo', '-n', 'systemctl', 'disable', f'wpa_supplicant@{iface}'])
        _run(['sudo', '-n', 'systemctl', 'stop', 'wpa_supplicant'])
        _run(['sudo', '-n', 'systemctl', 'disable', 'wpa_supplicant'])
        _run(['sudo', '-n', 'rm', '-f', sock_path])
        _run(['sudo', '-n', 'sh', '-c', f'pkill -f "wpa_supplicant.*-i{iface}" || true'])

        _run(['sudo', '-n', 'ip', 'addr', 'flush', 'dev', iface])
        _run(['sudo', '-n', 'ip', 'link', 'set', iface, 'down'])
        time.sleep(1)
        _run(['sudo', '-n', 'ip', 'link', 'set', iface, 'up'])
        time.sleep(1)

        _run(['sudo', '-n', 'systemctl', 'enable', 'NetworkManager'])
        ok, nm_err = _ensure_networkmanager_running()
        if not ok:
            return _fail_with_tethering_recovery(f'Hotspot起動に失敗: {nm_err}')

        _run(['sudo', '-n', nmcli_cmd, 'networking', 'on'])
        _run(['sudo', '-n', nmcli_cmd, 'radio', 'wifi', 'on'])

        _run(['sudo', '-n', iw_cmd, 'dev', iface, 'set', 'power_save', 'off'])

        # Safe teardown with delays
        _run(['sudo', '-n', nmcli_cmd, 'connection', 'down', 'Hotspot'])
        time.sleep(2)
        _run(['sudo', '-n', nmcli_cmd, 'connection', 'delete', 'Hotspot'])
        time.sleep(2)

        result = _run(
            ['sudo', '-n', nmcli_cmd, 'device', 'wifi', 'hotspot',
             'ifname', iface,
             'ssid', ssid,
             'password', password],
            timeout=40,
        )

        if result['returncode'] != 0:
            return _fail_with_tethering_recovery(
                f"Hotspot起動に失敗: {result['stderr'] or result['stdout']}"
            )

        _run(['sudo', '-n', nmcli_cmd, 'connection', 'modify', 'Hotspot', 'connection.autoconnect', 'yes'])
        _run(['sudo', '-n', nmcli_cmd, 'connection', 'modify', 'Hotspot', '802-11-wireless.powersave', '2'])
        _run(['sudo', '-n', nmcli_cmd, 'connection', 'modify', 'Hotspot', '802-11-wireless.band', 'bg'])
        _run(['sudo', '-n', nmcli_cmd, 'connection', 'modify', 'Hotspot', '802-11-wireless.channel', '6'])

        # APのIPを固定化（失敗しても継続）
        _run(['sudo', '-n', nmcli_cmd, 'connection', 'modify', 'Hotspot', 'ipv4.method', 'shared'])
        _run(['sudo', '-n', nmcli_cmd, 'connection', 'modify', 'Hotspot', 'ipv4.addresses', f'{AP_IP}/24'])
        _run(['sudo', '-n', nmcli_cmd, 'connection', 'down', 'Hotspot'])
        time.sleep(1)
        _run(['sudo', '-n', nmcli_cmd, 'connection', 'up', 'Hotspot'])
        time.sleep(2)

        _run(['sudo', '-n', iw_cmd, 'dev', iface, 'set', 'power_save', 'off'])

        ready, ready_err = _wait_for_ap_ready(iface, timeout=35)
        if not ready:
            logger.warning(f"AP readiness check failed, retry hotspot up: {ready_err}")
            _run(['sudo', '-n', nmcli_cmd, 'connection', 'up', 'Hotspot'], timeout=40)
            time.sleep(2)
            ready, ready_err = _wait_for_ap_ready(iface, timeout=20)
            if not ready:
                return _fail_with_tethering_recovery(f'AP起動後の確認に失敗: {ready_err}')

        # 設定を保存
        _save_wifi_settings('ap', ssid, password)

        # 現在のIPを取得（失敗時は既定値）
        current_ip = _get_primary_ip() or AP_IP
        if not (current_ip.startswith('192.168.4.') or current_ip.startswith('10.42.0.')):
            current_ip = AP_IP

        logger.info("Successfully switched to AP mode")
        return {
            'success': True,
            'message': f'APモードに切り替えました。スマホで「{ssid}」に接続してください。',
            'ip': current_ip,
            'ip_address': current_ip,
        }
    except Exception as e:
        logger.error(f"AP mode switch failed: {e}")
        return _fail_with_tethering_recovery(str(e))

def switch_to_tethering_mode(allow_ap_fallback=True):
    """
    テザリングモード（通常のWi-Fiクライアントモード）に切り替える

    allow_ap_fallback=False の場合は失敗時に AP へ戻さず、
    失敗情報のみ返します（再帰的な切替ループ防止用途）。
    """
    # 保存された設定からSSIDを取得（もしあれば）
    # ここでは実装簡略化のため、既存のwpa_supplicant.confを優先するか、Webから渡された値を使うべき
    # 引数がないので、UI側で入力させるのが理想だが、今のAPIは引数なし。
    # 実際は update_wifi_settings API経由で wpa_supplicant を書き換えるフローが必要。

    def _fail_with_ap_fallback(message):
        if not allow_ap_fallback:
            logger.warning(f"Tethering switch failed (AP fallback disabled): {message}")
            ip = _get_primary_ip()
            return {
                'success': False,
                'message': message,
                'fallback': None,
                'ip': ip,
                'ip_address': ip,
            }

        logger.warning(f"Tethering switch failed, fallback to AP: {message}")
        ap_settings = get_saved_ap_settings()
        fallback = switch_to_ap_mode(ap_settings.get('ssid'), ap_settings.get('password'))
        if fallback.get('success'):
            try:
                _save_wifi_settings('ap', ap_settings.get('ssid'), ap_settings.get('password'))
            except Exception as e:
                logger.warning(f"Failed to persist AP mode after fallback: {e}")
        ip = fallback.get('ip') or fallback.get('ip_address')
        return {
            'success': False,
            'message': message,
            'fallback': fallback,
            'ip': ip,
            'ip_address': ip,
        }
    
    if _is_networkmanager_running():
        try:
            nmcli_cmd = _resolve_executable('nmcli')
            logger.info("Switching to tethering mode: teardown hotspot (nmcli)")
            _run(['sudo', '-n', nmcli_cmd, 'connection', 'down', 'Hotspot'])
            time.sleep(2)
            _run(['sudo', '-n', nmcli_cmd, 'connection', 'delete', 'Hotspot'])
            time.sleep(1)
        except Exception as e:
            logger.warning(f"nmcli teardown failed (continue legacy): {e}")

    _run(['sudo', '-n', 'systemctl', 'stop', 'NetworkManager'])
    _run(['sudo', '-n', 'systemctl', 'disable', 'NetworkManager'])
    time.sleep(2)

    # Legacy: wpa_supplicant/dhcpcd mode
    # すでにwpa_supplicant.confが適切なら、単にインターフェース再起動
    try:
        logger.info("Switching to tethering mode (legacy)")
        iface = _detect_wifi_interface()
        iw_cmd = _resolve_executable('iw')

        _ensure_per_iface_wpa_conf(iface)
        _run(['sudo', '-n', 'systemctl', 'stop', 'hostapd'])
        _run(['sudo', '-n', 'systemctl', 'stop', 'dnsmasq'])

        _run(['sudo', '-n', 'ip', 'addr', 'flush', 'dev', iface])
        _run(['sudo', '-n', 'ip', 'link', 'set', iface, 'down'])
        time.sleep(1)
        _run(['sudo', '-n', 'ip', 'link', 'set', iface, 'up'])
        time.sleep(1)
        _run(['sudo', '-n', iw_cmd, 'dev', iface, 'set', 'power_save', 'off'])

        _run(['sudo', '-n', 'systemctl', 'enable', 'dhcpcd'])
        wpa_restart = _restart_wpa_supplicant_services(iface)
        if wpa_restart['returncode'] != 0:
            return _fail_with_ap_fallback(
                f"wpa_supplicant restart failed: {wpa_restart['stderr'] or wpa_restart['stdout']}"
            )
        time.sleep(2)

        _run(['sudo', '-n', 'systemctl', 'restart', 'dhcpcd'])

        reconfigure = _run_wpa_cli(['reconfigure'], iface=iface)
        if reconfigure['returncode'] != 0 or 'FAIL' in reconfigure['stdout']:
            _restart_wpa_supplicant_services(iface)
            time.sleep(2)
            reconfigure = _run_wpa_cli(['reconfigure'], iface=iface)

        if reconfigure['returncode'] != 0 or 'FAIL' in reconfigure['stdout']:
            return _fail_with_ap_fallback(
                f"wpa_cli reconfigure failed: {reconfigure['stderr'] or reconfigure['stdout']}"
            )

        time.sleep(3)

        reconnect = _run_wpa_cli(['reconnect'], iface=iface)
        if reconnect['returncode'] != 0 or 'FAIL' in reconnect['stdout']:
            return _fail_with_ap_fallback(
                f"wpa_cli reconnect failed: {reconnect['stderr'] or reconnect['stdout']}"
            )
        time.sleep(2)

        _run(['sudo', '-n', 'dhcpcd', '-n', iface])
        time.sleep(2)

        connected = check_tethering_connection(timeout=30)
        if not connected:
            return _fail_with_ap_fallback('テザリング接続に失敗したためAPモードに戻しました')

        _save_wifi_settings('tethering', None, None)
        ip = _get_primary_ip()
        return {
            'success': True,
            'message': '設定を再読み込みしました (Legacy mode)',
            'ip': ip,
            'ip_address': ip,
        }
    except Exception as e:
        return _fail_with_ap_fallback(str(e))

def _save_wifi_settings(mode, ssid, password):
    """Wi-Fi設定を保存"""
    try:
        settings = {}
        if os.path.exists(SETTINGS_FILE):
            with open(SETTINGS_FILE, 'r') as f:
                settings = json.load(f)
        
        settings['wifi_mode'] = mode
        if ssid:
            settings['ap_ssid'] = ssid
        if password:
            settings['ap_password'] = password
        
        with open(SETTINGS_FILE, 'w') as f:
            json.dump(settings, f, indent=2)
            
    except Exception as e:
        logger.error(f"Failed to save Wi-Fi settings: {e}")

def get_saved_ap_settings():
    """保存されているAP設定を取得"""
    try:
        if os.path.exists(SETTINGS_FILE):
            with open(SETTINGS_FILE, 'r') as f:
                settings = json.load(f)
            return {
                'ssid': settings.get('ap_ssid', _get_default_ap_ssid()),
                'password': settings.get('ap_password', _get_default_ap_password())
            }
    except Exception:
        pass
    return {'ssid': _get_default_ap_ssid(), 'password': _get_default_ap_password()}

if __name__ == '__main__':
    import sys
    logging.basicConfig(level=logging.INFO)
    if len(sys.argv) < 2:
        print(f"Current mode: {get_current_mode()}")
        print(f"Status: {get_wifi_status()}")

