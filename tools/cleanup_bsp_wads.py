import struct
import os
import re
import sys

def parse_wad(wad_path):
    textures = set()
    try:
        with open(wad_path, 'rb') as f:
            header = f.read(12)
            if len(header) < 12: return textures
            magic, numlumps, infotableofs = struct.unpack('<4sii', header)
            if magic not in [b'WAD2', b'WAD3']: return textures
            f.seek(infotableofs)
            for _ in range(numlumps):
                lump_info = f.read(32)
                if len(lump_info) < 32: break
                name = lump_info[16:32].split(b'\0')[0].decode('ascii', errors='ignore').lower()
                textures.add(name)
    except Exception: pass
    return textures

def get_used_wads(bsp_path, available_wads):
    try:
        with open(bsp_path, 'rb') as f:
            header_data = f.read(124)
            if len(header_data) < 124: return None
            lumps = [struct.unpack('<ii', header_data[4 + i*8 : 4 + (i+1)*8]) for i in range(15)]
            
            # Texture lump (2)
            tex_offset, tex_length = lumps[2]
            f.seek(tex_offset)
            nummiptex_data = f.read(4)
            if not nummiptex_data: return None
            nummiptex = struct.unpack('<i', nummiptex_data)[0]
            miptex_offsets = struct.unpack(f'<{nummiptex}i', f.read(nummiptex * 4))
            
            external_textures = []
            for mo in miptex_offsets:
                if mo == -1: continue 
                f.seek(tex_offset + mo)
                miptex_data = f.read(40)
                if len(miptex_data) < 40: continue
                name = miptex_data[:16].split(b'\0')[0].decode('ascii', errors='ignore').lower()
                # Check if first offset is 0 (external)
                if struct.unpack('<I', miptex_data[24:28])[0] == 0:
                    external_textures.append(name)
            
            # Get original specified WADs to maintain some context if desired, 
            # but we'll focus on what's actually needed.
            ent_offset, ent_length = lumps[0]
            f.seek(ent_offset)
            entities = f.read(ent_length).decode('ascii', errors='ignore')
            wad_match = re.search(r'"wad"\s+"([^"]+)"', entities)
            original_wads = []
            if wad_match:
                original_wads = [os.path.basename(p.replace('\\', '/')).lower() for p in wad_match.group(1).split(';') if p.strip()]

            used_wads = set()
            for tex in external_textures:
                found = False
                # Prioritize original WADs if they have the texture
                for ow in original_wads:
                    if ow in available_wads and tex in available_wads[ow]:
                        used_wads.add(ow)
                        found = True
                        break
                if found: continue
                
                # Otherwise find it in any available WAD
                for wad_name, wad_textures in available_wads.items():
                    if tex in wad_textures:
                        used_wads.add(wad_name)
                        break
            
            return sorted(list(used_wads))
    except Exception as e: 
        print(f"Error in get_used_wads: {e}")
        return None

def cleanup_bsp(bsp_path, used_wads):
    try:
        with open(bsp_path, 'rb+') as f:
            header_data = f.read(124)
            ent_offset, ent_length = struct.unpack('<ii', header_data[4:12])
            
            f.seek(ent_offset)
            ent_data = f.read(ent_length)
            try:
                entities = ent_data.decode('ascii')
            except UnicodeDecodeError:
                entities = ent_data.decode('ascii', 'ignore')

            # Build new WAD string
            new_wad_val = ";".join(used_wads)
            if new_wad_val: new_wad_val += ";"
            
            # Replace the wad key
            # Standard pattern: "wad" "path;path;"
            new_entities = re.sub(r'("wad"\s+)"[^"]*"', rf'\1"{new_wad_val}"', entities)
            
            if new_entities == entities:
                return False, "No changes needed"

            new_ent_data = new_entities.encode('ascii')
            if len(new_ent_data) > ent_length:
                return False, f"New entity lump too large ({len(new_ent_data)} > {ent_length})"

            # Pad with null bytes
            new_ent_data = new_ent_data.ljust(ent_length, b'\0')
            
            f.seek(ent_offset)
            f.write(new_ent_data)
            return True, "Successfully updated"
            
    except Exception as e:
        return False, str(e)

def main():
    project_root = os.getcwd()
    wad_files = [f for f in os.listdir(project_root) if f.lower().endswith('.wad')]
    available_wads = {wf.lower(): parse_wad(os.path.join(project_root, wf)) for wf in wad_files}
    
    maps_dir = os.path.join(project_root, 'maps')
    bsp_files = sorted([f for f in os.listdir(maps_dir) if f.lower().endswith('.bsp')])
    
    print(f"Cleaning up {len(bsp_files)} BSP files...")
    for bf in bsp_files:
        bsp_path = os.path.join(maps_dir, bf)
        used = get_used_wads(bsp_path, available_wads)
        if used is None:
            print(f"  {bf:20}: Error reading textures")
            continue
            
        success, msg = cleanup_bsp(bsp_path, used)
        status = "UPDATED" if success else "SKIPPED"
        print(f"  {bf:20}: {status} ({msg})")

if __name__ == "__main__":
    main()
