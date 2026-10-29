import struct
import os
import re
import sys

def parse_wad(wad_path):
    textures = set()
    try:
        with open(wad_path, 'rb') as f:
            header = f.read(12)
            if len(header) < 12:
                return textures
            magic, numlumps, infotableofs = struct.unpack('<4sii', header)
            if magic not in [b'WAD2', b'WAD3']:
                return textures
            
            f.seek(infotableofs)
            for _ in range(numlumps):
                lump_info = f.read(32)
                if len(lump_info) < 32:
                    break
                # WADLumpInfo: filepos (4), disksize (4), size (4), type (1), compression (1), pad (2), name (16)
                name_bytes = lump_info[16:32]
                name = name_bytes.split(b'\0')[0].decode('ascii', errors='ignore').lower()
                textures.add(name)
    except Exception as e:
        print(f"Error parsing WAD {wad_path}: {e}")
    return textures

def check_bsp(bsp_path, available_wads):
    results = {
        'missing_textures': [],
        'unused_wads': [],
        'specified_wads': [],
        'external_textures': []
    }
    
    try:
        with open(bsp_path, 'rb') as f:
            header_data = f.read(124)
            if len(header_data) < 124:
                return None
            version = struct.unpack('<i', header_data[:4])[0]
            if version != 30:
                # print(f"Unsupported BSP version {version} in {bsp_path}")
                return None
            
            lumps = []
            for i in range(15):
                offset, length = struct.unpack('<ii', header_data[4 + i*8 : 4 + (i+1)*8])
                lumps.append((offset, length))
            
            # Entity lump (0)
            ent_offset, ent_length = lumps[0]
            f.seek(ent_offset)
            entities = f.read(ent_length).decode('ascii', errors='ignore')
            
            # Find the "wad" key in worldspawn (usually the first entity)
            # It's a key-value pair "wad" "path/to/wad1.wad;path/to/wad2.wad"
            wad_match = re.search(r'"wad"\s+"([^"]+)"', entities)
            specified_wads = []
            if wad_match:
                wad_paths = wad_match.group(1).split(';')
                for wp in wad_paths:
                    wp = wp.strip()
                    if not wp: continue
                    # Handle both Windows and Unix paths, and absolute paths
                    wad_name = os.path.basename(wp.replace('\\', '/')).lower()
                    if wad_name not in specified_wads:
                        specified_wads.append(wad_name)
            
            results['specified_wads'] = specified_wads
            
            # Texture lump (2)
            tex_offset, tex_length = lumps[2]
            f.seek(tex_offset)
            nummiptex_data = f.read(4)
            if not nummiptex_data:
                return None
            nummiptex = struct.unpack('<i', nummiptex_data)[0]
            miptex_offsets_data = f.read(nummiptex * 4)
            if len(miptex_offsets_data) < nummiptex * 4:
                return None
            miptex_offsets = struct.unpack(f'<{nummiptex}i', miptex_offsets_data)
            
            external_textures = []
            for mo in miptex_offsets:
                if mo == -1: continue 
                f.seek(tex_offset + mo)
                miptex_data = f.read(40)
                if len(miptex_data) < 40:
                    continue
                name = miptex_data[:16].split(b'\0')[0].decode('ascii', errors='ignore').lower()
                offsets = struct.unpack('<4I', miptex_data[24:40])
                
                # If offsets[0] is 0, the texture is external (in a WAD)
                if offsets[0] == 0:
                    external_textures.append(name)
            
            results['external_textures'] = external_textures
            
            # Verification
            used_wads = set()
            missing = []
            for tex in external_textures:
                found = False
                # First check specified WADs
                for wad_name in specified_wads:
                    if wad_name in available_wads and tex in available_wads[wad_name]:
                        found = True
                        used_wads.add(wad_name)
                        break
                
                if not found:
                    # Check if it's in ANY available WAD even if not specified
                    found_anywhere = False
                    for wad_name, wad_textures in available_wads.items():
                        if tex in wad_textures:
                            found_anywhere = wad_name
                            break
                    
                    if found_anywhere:
                        missing.append(f"{tex} (found in {found_anywhere}, but NOT specified in BSP)")
                    else:
                        missing.append(f"{tex} (NOT FOUND ANYWHERE)")
            
            results['missing_textures'] = missing
            results['used_wads'] = list(used_wads)
            results['unused_wads'] = [w for w in specified_wads if w not in used_wads]
            
    except Exception as e:
        print(f"Error checking BSP {bsp_path}: {e}")
        return None
        
    return results

def main():
    # 1. Find all WADs in root
    project_root = os.getcwd()
    wad_files = [f for f in os.listdir(project_root) if f.lower().endswith('.wad')]
    
    available_wads = {}
    for wf in wad_files:
        available_wads[wf.lower()] = parse_wad(os.path.join(project_root, wf))
    
    print(f"Indexed {len(available_wads)} WAD files in project root.")
    
    # 2. Find all BSPs in maps/
    maps_dir = os.path.join(project_root, 'maps')
    if not os.path.exists(maps_dir):
        print("Maps directory not found.")
        return
    
    bsp_files = [f for f in os.listdir(maps_dir) if f.lower().endswith('.bsp')]
    bsp_files.sort()
    
    total_missing = 0
    total_unused_wads = 0
    
    global_wad_usage = {w: 0 for w in available_wads.keys()}
    
    for bf in bsp_files:
        bsp_path = os.path.join(maps_dir, bf)
        res = check_bsp(bsp_path, available_wads)
        if not res:
            continue
        
        for w in res['used_wads']:
            if w in global_wad_usage:
                global_wad_usage[w] += 1

        has_issues = res['missing_textures'] or res['unused_wads']
        
        if has_issues:
            print(f"\n--- {bf} ---")
            if res['external_textures']:
                print(f"  External textures: {len(res['external_textures'])}")
            else:
                print(f"  All textures are internal.")

            if res['used_wads']:
                print(f"  Used WADs:")
                for uw in res['used_wads']:
                    print(f"    - {uw}")

            if res['unused_wads']:
                present_unused = [w for w in res['unused_wads'] if w in available_wads]
                absent_unused = [w for w in res['unused_wads'] if w not in available_wads]
                
                if present_unused:
                    print(f"  Unused WADs (present in project):")
                    for w in present_unused:
                        print(f"    - {w}")
                    total_unused_wads += len(present_unused)
                
                if absent_unused:
                    print(f"  Unused WADs (NOT in project):")
                    for w in absent_unused:
                        print(f"    - {w}")
            
            if res['missing_textures']:
                print(f"  Missing textures ({len(res['missing_textures'])}):")
                for mt in res['missing_textures']:
                    print(f"    - {mt}")
                total_missing += len(res['missing_textures'])

    print(f"\nSummary:")
    print(f"Total BSPs checked: {len(bsp_files)}")
    print(f"Total missing texture references: {total_missing}")
    print(f"Total unused WAD references in BSPs: {total_unused_wads}")
    
    print(f"\nGlobal WAD Usage (in project):")
    for wad, count in global_wad_usage.items():
        status = "USED" if count > 0 else "--- UNUSED BY ANY BSP ---"
        print(f"  {wad:15}: {count:2} maps ({status})")

if __name__ == "__main__":
    main()
