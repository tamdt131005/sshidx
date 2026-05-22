{ pkgs, ... }: {
  packages = with pkgs; [
    qemu_full
    rclone
    wget
    cloudflared
    novnc
    python3Packages.websockify
    util-linux
    python3
  ];

  idx.workspace.onStart = {
    setup-and-run = ''
      mkdir -p /home/user/linux-server-idx
      chmod +x run.sh
      bash run.sh
    '';
  };
}  
