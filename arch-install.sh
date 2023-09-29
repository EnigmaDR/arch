#!/bin/bash

# Sjekk om systemet er i UEFI-modus
if [ -d /sys/firmware/efi/efivars ]; then
    echo "UEFI-modus oppdaget"
    MODE="UEFI"
else
    echo "Legacy BIOS-modus oppdaget"
    MODE="BIOS"
fi

# Aktiver nettverket
echo "Aktiverer nettverket..."
systemctl start dhcpcd
systemctl enable dhcpcd

# Oppdater systemklokken
timedatectl set-ntp true

# Opprett partisjoner
echo "Oppretter partisjoner..."
if [ "$MODE" == "UEFI" ]; then
    parted /dev/nvme0n1 mklabel gpt
    parted /dev/nvme0n1 mkpart primary fat32 1MiB 513MiB
    parted /dev/nvme0n1 set 1 boot on
    parted /dev/nvme0n1 mkpart primary btrfs 513MiB 100%
    mkfs.fat -F32 /dev/nvme0n1p1
else
    parted /dev/nvme0n1 mklabel msdos
    parted /dev/nvme0n1 mkpart primary ext4 1MiB 513MiB
    parted /dev/nvme0n1 set 1 boot on
    parted /dev/nvme0n1 mkpart primary btrfs 513MiB 100%
    mkfs.ext4 /dev/nvme0n1p1
fi

mkfs.btrfs -L arch /dev/nvme0n1p2

# Monter rotsystemet
mount /dev/nvme0n1p2 /mnt

# Opprett Btrfs subvolumer
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots

# Monter subvolumene
umount /mnt
mount -o noatime,compress=zstd,subvol=@ /dev/nvme0n1p2 /mnt
mkdir /mnt/{boot,home,.snapshots}
mount -o noatime,compress=zstd,subvol=@home /dev/nvme0n1p2 /mnt/home
mount -o noatime,compress=zstd,subvol=@snapshots /dev/nvme0n1p2 /mnt/.snapshots

# Monter boot-partisjonen
if [ "$MODE" == "UEFI" ]; then
    mkdir /mnt/boot
    mount /dev/sda1 /mnt/boot
fi

# Installere base system
echo "Installerer base system..."
pacstrap /mnt base base-devel linux linux-firmware sudo nano vi amd-ucode git

# Generer fstab-filen
genfstab -U /mnt >> /mnt/etc/fstab

# Chroot inn i det nye systemet
arch-chroot /mnt

# Konfigurer tidssone og språk
echo "Konfigurerer tidssone og språk..."
ln -sf /usr/share/zoneinfo/Europe/Oslo /etc/localtime
hwclock --systohc
sed -i '/en_US.UTF-8/s/^#//' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# Sett tastaturoppsettet i /etc/vconsole.conf
echo "KEYMAP=no-latin1" > /etc/vconsole.conf

# Sett hostname
echo "Skriv inn vertsnavn (f.eks., my-arch-pc):"
read hostname
echo $hostname > /etc/hostname

# Legg til vertsoppføring
echo "Legger til vertsinformasjon i /etc/hosts..."
echo "127.0.0.1     localhost" >> /etc/hosts
echo "::1           localhost" >> /etc/hosts
echo "127.0.1.1     $hostname.localdomain  $hostname" >> /etc/hosts

# Opprett initramfs
echo "Oppretter initramfs..."
mkinitcpio -p linux

# Sett passord for root
#echo "Angi passord for root:"
#passwd

# Opprett en ny bruker med sudo-tilgang
echo "Oppretter en ny bruker med sudo-tilgang..."
read -p "Skriv inn ønsket brukernavn: " new_username
useradd -m -G wheel $new_username

# Sett passord for den nye brukeren
passwd $new_username

# Fjern kommentaren fra wheel-gruppen i sudoers-filen
echo "Aktiverer sudo-tilgang for wheel-gruppen..."
sed -i '/%wheel ALL=(ALL) ALL/s/^# //' /etc/sudoers

echo "Ny bruker '$new_username' er opprettet med sudo-tilgang."


# Installer og konfigurer bootloader (GRUB for UEFI, GRUB for BIOS)
if [ "$MODE" == "UEFI" ]; then
    pacman -S grub efibootmgr
    grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
else
    pacman -S grub
    grub-install --target=i386-pc /dev/sda
fi

grub-mkconfig -o /boot/grub/grub.cfg

# Installer nødvendige pakker
echo "Installerer nødvendige pakker..."
pacman -S networkmanager mesa

# Aktiverer networkmanager
echo "Aktiverer NetworkManager"
systemctl enable NetworkManager

# Avslutt chroot og reboots
#exit
#umount -R /mnt
#echo "Installasjonen er fullført. Systemet vil nå starte på nytt."
#reboot
