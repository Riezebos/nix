{...}: {
  # RAID1 mdraid across both Samsung PM983 NVMes + LUKS + ext4.
  # Both disks referenced by stable by-id paths (never /dev/nvmeN).
  #
  # Layout on each disk (matching GPT on both so either drive alone can boot):
  #   - 1 MiB BIOS boot partition (EF02) for GRUB legacy BIOS stage1.5
  #   - 1 GiB /boot (ext4, no LUKS so GRUB can read it). Kept as two separate
  #     partitions mounted at /boot-1 and /boot-2 so GRUB's `mirroredBoots`
  #     option can install and maintain both independently.
  #   - rest of the disk as an mdraid member for RAID1 of the root.
  # mdraid RAID1 sits on top of the two large partitions. LUKS2 wraps the md
  # device, ext4 lives on the decrypted volume.
  flake.nixosModules.foundryDisko = {
    disko.devices = {
      disk = {
        nvme0 = {
          type = "disk";
          device = "/dev/disk/by-id/nvme-SAMSUNG_MZQLB960HAJR-00007_S437NF0M501871";
          content = {
            type = "gpt";
            partitions = {
              bios = {
                size = "1M";
                type = "EF02";
                priority = 1;
              };
              boot = {
                size = "1G";
                content = {
                  type = "filesystem";
                  format = "ext4";
                  mountpoint = "/boot-1";
                  mountOptions = ["nofail"];
                };
              };
              raid = {
                size = "100%";
                content = {
                  type = "mdraid";
                  name = "root";
                };
              };
            };
          };
        };
        nvme1 = {
          type = "disk";
          device = "/dev/disk/by-id/nvme-SAMSUNG_MZQLB960HAJR-00007_S437NF0M501883";
          content = {
            type = "gpt";
            partitions = {
              bios = {
                size = "1M";
                type = "EF02";
                priority = 1;
              };
              boot = {
                size = "1G";
                content = {
                  type = "filesystem";
                  format = "ext4";
                  mountpoint = "/boot-2";
                  mountOptions = ["nofail"];
                };
              };
              raid = {
                size = "100%";
                content = {
                  type = "mdraid";
                  name = "root";
                };
              };
            };
          };
        };
      };
      mdadm = {
        root = {
          type = "mdadm";
          level = 1;
          content = {
            type = "luks";
            name = "cryptroot";
            settings.allowDiscards = true;
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/";
            };
          };
        };
      };
    };
  };
}
