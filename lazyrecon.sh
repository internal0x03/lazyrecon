#!/bin/bash

# Invoke with sudo because of masscan/nmap

# Config
altdnsWordlist=./lazyWordLists/altdns_wordlist_uniq.txt
dirsearchWordlist=./lazyWordLists/curated.txt
resolvers=./resolvers/mini_resolvers.txt
dirsearchThreads=200

# definitions
enumeratesubdomains(){
  echo "[phase 1] Enumerating all known domains using:"

  # Passive subdomain enumeration
  echo "subfinder..."
  subfinder -d $1 -o ./$1/$foldername/subfinder-list.txt
  echo "assetfinder..."
  assetfinder --subs-only $1 > ./$1/$foldername/assetfinder-list.txt

  # Active subdomain enumeration
  echo "amass..."
  amass enum -brute -min-for-recursive 2 -rf $resolvers -log ./$1/$foldername/amass_errors.log -d $1 -o ./$1/$foldername/amass-list.txt

  # sort enumerated subdomains
  sort -u ./$1/$foldername/subfinder-list.txt ./$1/$foldername/amass-list.txt ./$1/$foldername/assetfinder-list.txt > ./$1/$foldername/enumerated_subdomains_tmp.txt
  echo "shuffledns bruteforcing..."
  shuffledns -d $1 -retries 1 -r $resolvers -w $altdnsWordlist -o ./$1/$foldername/shuffledns-list.txt
  # one more time sort enumerated subdomains to avoid duplicates
  sort -u ./$1/$foldername/enumerated_subdomains_tmp.txt ./$1/$foldername/shuffledns-list.txt > ./$1/$foldername/enumerated-subdomains.txt
}

checkwaybackurls(){
  echo "gau..."
  # gau -subs mean include subdomains
  cat ./$1/$foldername/enumerated-subdomains.txt | gau -subs -o ./$1/$foldername/gau_output.txt
  echo "waybackurls..."
  cat ./$1/$foldername/enumerated-subdomains.txt | waybackurls > ./$1/$foldername/waybackurls_output.txt

  # wayback_output.txt needs for checkparams
  sort -u ./$1/$foldername/gau_output.txt ./$1/$foldername/waybackurls_output.txt > ./$1/$foldername/wayback_output.txt
  cat ./$1/$foldername/wayback_output.txt | unfurl --unique domains > ./$1/$foldername/wayback-subdomains-list.txt
  # parse for only subdomains to got target specific wordlist for permutation
  # cat ./$1/$foldername/wayback_output.txt | unfurl format %S | sort | uniq > ./$1/$foldername/wayback-subdomains-wordlist.txt
}

sortsubdomains(){
  sort -u ./$1/$foldername/enumerated-subdomains.txt ./$1/$foldername/wayback-subdomains-list.txt > ./$1/$foldername/1-real-subdomains.txt
}

permutatesubdomains(){
  # prepare target specific subdomains wordlist to run manually agains specific target (time optimization)
  # sort -u $altdnsWordlist ./$1/$foldername/wayback-subdomains-wordlist.txt > ./$1/$foldername/subs_wordlist.txt
  echo "altdns..."
  altdns -i ./$1/$foldername/1-real-subdomains.txt -o ./$1/$foldername/altdns_output.txt -w $altdnsWordlist

  sort -u ./$1/$foldername/1-real-subdomains.txt ./$1/$foldername/altdns_output.txt > ./$1/$foldername/2-all-subdomains.txt
}

dnsprobing(){
  # check file wirteup successfully from previous step
  while [ ! -s ./$1/$foldername/2-all-subdomains.txt ]; do
    echo "[dnsprobing] 2-all-subdomains.txt empty, sleep 1"
    sleep 1
  done
  echo "dnsprobe..."
  dnsprobe -l ./$1/$foldername/2-all-subdomains.txt -r A -s $resolvers -o ./$1/$foldername/dnsprobe_output.txt

  # split resolved hosts ans its IP (for masscan)
  cut -f1 -d ' ' ./$1/$foldername/dnsprobe_output.txt > ./$1/$foldername/dnsprobe_subdomains.txt
  cut -f2 -d ' ' ./$1/$foldername/dnsprobe_output.txt | sort -u > ./$1/$foldername/dnsprobe_ip.txt
}

checkhttprobe(){
  echo "[phase 2] Starting httpx probe testing..."
  # resolve IP and hosts with http|https for bruteforce
  httpx -l ./$1/$foldername/dnsprobe_ip.txt -silent -follow-host-redirects -fc 300,301,302,303 -o ./$1/$foldername/httpx_output_1.txt
  httpx -l ./$1/$foldername/2-all-subdomains.txt -silent -follow-host-redirects -fc 300,301,302,303 -o ./$1/$foldername/httpx_output_2.txt

  sort -u ./$1/$foldername/httpx_output_1.txt ./$1/$foldername/httpx_output_2.txt > ./$1/$foldername/3-all-subdomain-live-scheme.txt
  # tr -d '\[\]' < ./$1/$foldername/httpx_output.txt > ./$1/$foldername/tr_httpx_output.txt

  # check file wirteup successfully from previous step
  # while [ ! -s ./$1/$foldername/httpx_output.txt ]; do
  #   echo "[checkhttprobe] httpx_output.txt empty, sleep 1"
  #   sleep 1
  # done

  # split resolved hosts ans its IP (for masscan)
  # cut -f1 -d ' ' ./$1/$foldername/httpx_output.txt > ./$1/$foldername/3-all-subdomain-live-scheme.txt
  # cut -f2 -d ' ' ./$1/$foldername/httpx_output.txt | sort -u > ./$1/$foldername/3-all-subdomain-live-ip.txt
}

nucleitest(){
  if [ ! -e ./$1/$foldername/3-all-subdomain-live-scheme.txt ]; then
    echo "[nuclei] There is no live hosts. exit 1"
    exit 1
  fi
  echo "[phase 3] nuclei testing..."
  nuclei -l ./$1/$foldername/3-all-subdomain-live-scheme.txt -t ../nuclei-templates/generic-detections/ -t ../nuclei-templates/vulnerabilities/ -t ../nuclei-templates/security-misconfiguration/ -t ../nuclei-templates/cves/ -t ../nuclei-templates/misc/ -t ../nuclei-templates/files/ -t ../nuclei-templates/subdomain-takeover -o ./$1/$foldername/nuclei_output.txt
}

# nmap(){
#   echo "[phase 7] Test for unexpected open ports..."
#   nmap -sS -PN -T4 --script='http-title' -oG nmap_output_og.txt  
# }
masscantest(){
  # max-rate for accuracy
  masscan -p1-65535 -iL ./$1/$foldername/dnsprobe_ip.txt --max-rate 300 --open-only -oL ./$1/$foldername/masscan_output.txt
}
nmap_nse(){
  awk '{ print $4 }' ./$1/$foldername/masscan_output.txt | sort | uniq > ./$1/$foldername/nmap_input.txt
  nmap --script "auth" -iL ./$1/$foldername/nmap_input.txt
  nmap --script=nfs-ls -iL ./$1/$foldername/nmap_input.txt

}

smuggler(){
  echo "[phase 7] Try to find request smuggling vulnerabilities..."
  smuggler.py -u ./$1/$foldername/3-all-subdomain-live-scheme.txt

  # check for VULNURABLE keyword
  if [ -s ./smuggler/output ]; then
    cat ./smuggler/output | grep 'VULNERABLE' > ./$1/$foldername/smugglinghosts.txt
    if [ -s ./$1/$foldername/smugglinghosts.txt ]; then
      printf "${RB_RED}%sSmuggling vulnerability found under the next hosts:${RESET}"
      echo
      cat ./$1/$foldername/smugglinghosts.txt | grep 'VULN'
    else
      echo "There are no Request Smuggling host found"
    fi
  else
    echo "smuggler doesn't provide the output, check it issue!"
  fi
}

# prepare custom wordlist for directory bruteforce
checkparams(){
  echo "[phase 8] Prepare custom wordlist using unfurl"
  cat ./$1/$foldername/wayback_output.txt | unfurl paths | sed 's/\///' > ./$1/$foldername/wayback_params_list.txt
  # merge base dirsearchWordlist with target-specific for manually use only for specific target (save your time)
  sort -u ./$1/$foldername/wayback_params_list.txt $dirsearchWordlist > ./$1/$foldername/wordlist.txt
  sudo sed -i .bak '/^[[:space:]]*$/d' ./$1/$foldername/wordlist.txt
}

ffufbrute(){
  echo "[phase 9] Start directory bruteforce..."
  iterator=1
  while read subdomain; do
    # dirsearchWordlist used because time optimization, use wordlist.txt only for specific target
    ffuf -c -u ${subdomain}/FUZZ -mc all -fc 300,301,302,303,304,500,501,502,503 -recursion -recursion-depth 3 -w $dirsearchWordlist -t $dirsearchThreads -o ./$1/$foldername/ffuf/${iterator}.csv -of csv
    iterator=$((iterator+1))
  done < ./$1/$foldername/3-all-subdomain-live-scheme.txt
}

recon(){
  enumeratesubdomains $1
  checkwaybackurls $1
  sortsubdomains $1
  permutatesubdomains $1

  dnsprobing $1
  checkhttprobe $1

  nucleitest $1
  masscantest $1
  nmap_nse $1

  smuggler $1

  checkparams $1
  ffufbrute $1

  # echo "Generating HTML-report here..."
  echo "Lazy done."
}


main(){
  if [ -d "./$1" ]
  then
    echo "This is a known target."
  else
    mkdir ./$1
  fi
  if [ -s ./smuggler/output ]; then
    rm ./smuggler/output
  fi

  mkdir ./$1/$foldername
  # ffuf dir uses to store brute output
  mkdir ./$1/$foldername/ffuf/
  # subfinder list of subdomains
  touch ./$1/$foldername/subfinder-list.txt 
  # amass list of subdomains
  touch ./$1/$foldername/amass-list.txt
  # assetfinder list of subdomains
  touch ./$1/$foldername/assetfinder-list.txt
  # shuffledns list of subdomains
  touch ./$1/$foldername/shuffledns-list.txt
  # gau/waybackurls list of subdomains
  touch ./$1/$foldername/wayback-subdomains-list.txt
  # gau list of only params
  touch ./$1/$foldername/wayback_params_list.txt

  # mkdir ./$1/$foldername/reports/
  # echo "Reports goes to: ./${1}/${foldername}"

    recon $1
    # master_report $1
}

usage(){
  echo "Usage: $FUNCNAME \"<target>\""
  echo "Example: $FUNCNAME \"example.com\""
}

invokation(){
  echo "Warn: unexpected positional argument: $1"
  echo "$(basename $0) [[-h] | [--help]]"
}

# check for specifiec arguments (help)
checkhelp(){
  while [ "$1" != "" ]; do
      case $1 in
          -h | --help )           usage
                                  exit
                                  ;;
          # * )                     invokation $1
          #                         exit 1
      esac
      shift
  done
}


##### Main
echo "Check params 1: $@"

if [ $# -eq 1 ]; then
  checkhelp "$@"
# else
#   if [ $# -ne 3 ]; then
#     echo "Error: expected arguments count"
#     usage
#     exit 1
#   fi
fi
if [[ -z $@ ]]; then
  usage
  exit 1
fi

./logo.sh
path=$(pwd)
# to avoid cleanup or `sort -u` operation
foldername=recon-$(date +"%y-%m-%d_%H-%M-%S")

# invoke with asn
main $1
