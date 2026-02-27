#lang racket/base

(require racket/list
         racket/string
         "util.rkt")

(provide legacy-plt-version-tokens
         legacy-plt-version?
         legacy-plt-release-info
         legacy-plt-request-info)

(define legacy-plt-version-tokens
  '("053" "103" "103p1" "200" "201" "202" "203" "204" "205" "206" "206p1" "207" "208" "209" "300" "301" "350" "351" "352" "360" "370" "371" "372" "4.0" "4.0.1" "4.0.2" "4.1" "4.1.1" "4.1.2" "4.1.3" "4.1.4" "4.1.5" "4.2" "4.2.1" "4.2.2" "4.2.3" "4.2.4" "4.2.5"))

(define legacy-plt-release-info
  (hash
   "053"
   (hasheq 'reason "PLT Scheme v053 does not publish a Linux installer."
           'artifacts null)
   "103"
   (hasheq 'install-kind 'tgz
           'artifacts
           (list
            (hasheq 'arch "i386" 'platform "linux" 'ext "tgz" 'filename "plt-103-bin-i386-linux.tgz" 'url "http://download.plt-scheme.org/bundles/103/plt/plt-103-bin-i386-linux.tgz" 'sha256 "21a51e001982dd748414ebc3d5ee3400209f20ba4532e985650506fced227405" )
            ))
   "103p1"
   (hasheq 'install-kind 'tgz
           'artifacts
           (list
            (hasheq 'arch "i386" 'platform "linux" 'ext "tgz" 'filename "plt-103p1-bin-i386-linux.tgz" 'url "http://download.plt-scheme.org/bundles/103p1/plt/plt-103p1-bin-i386-linux.tgz" 'sha256 "7090e2d7df07c17530e50cbc5fde67b51b39f77c162b7f20413242dca923a20a" )
            ))
   "200"
   (hasheq 'install-kind 'tgz
           'artifacts
           (list
            (hasheq 'arch "i386" 'platform "linux" 'ext "tgz" 'filename "plt-200-bin-i386-linux.tgz" 'url "http://download.plt-scheme.org/bundles/200/plt/plt-200-bin-i386-linux.tgz" 'sha256 "dcb94fb3e66ed60d9f27b4d08dc845c37108a705f5e88f7e7620880b12085f76" )
            ))
   "201"
   (hasheq 'install-kind 'tgz
           'artifacts
           (list
            (hasheq 'arch "i386" 'platform "linux" 'ext "tgz" 'filename "plt-201-bin-i386-linux.tgz" 'url "http://download.plt-scheme.org/bundles/201/plt/plt-201-bin-i386-linux.tgz" 'sha256 "857f9853b3ce7487978a8a12d6b572106c845041376426d231e03408ccba7821" )
            ))
   "202"
   (hasheq 'install-kind 'tgz
           'artifacts
           (list
            (hasheq 'arch "i386" 'platform "linux" 'ext "tgz" 'filename "plt-202-bin-i386-linux.tgz" 'url "http://download.plt-scheme.org/bundles/202/plt/plt-202-bin-i386-linux.tgz" 'sha256 "6635ab9ad7d915173920214c2bd4de0fbc4ed14730355055d382bca690e05a21" )
            ))
   "203"
   (hasheq 'reason "PLT Scheme v203 only publishes a Linux RPM, which rackup does not support."
           'artifacts null)
   "204"
   (hasheq 'reason "PLT Scheme v204 does not publish a Linux installer."
           'artifacts null)
   "205"
   (hasheq 'install-kind 'tgz
           'artifacts
           (list
            (hasheq 'arch "i386" 'platform "linux" 'ext "tgz" 'filename "plt-205-bin-i386-linux.tgz" 'url "http://download.plt-scheme.org/bundles/205/plt/plt-205-bin-i386-linux.tgz" 'sha256 "edb50403688096afd98017a1932fd96e12c5fda93eb4741cf614c352431c38ab" )
            ))
   "206"
   (hasheq 'install-kind 'shell-basic
           'artifacts
           (list
            (hasheq 'arch "i386" 'platform "linux" 'ext "sh" 'filename "plt-206-bin-i386-linux.sh" 'url "http://download.plt-scheme.org/bundles/206/plt/plt-206-bin-i386-linux.sh" 'sha256 "e1ec6e5be7971f155992a05c1de9e5810cd3d2f336ddb898ae2ef8212fc42b20" )
            ))
   "206p1"
   (hasheq 'install-kind 'shell-basic
           'artifacts
           (list
            (hasheq 'arch "i386" 'platform "linux" 'ext "sh" 'filename "plt-206p1-bin-i386-linux.sh" 'url "http://download.plt-scheme.org/bundles/206p1/plt/plt-206p1-bin-i386-linux.sh" 'sha256 "62c470041133159e8e9cb2a5b8666a17c0f363235c524f77711477979a82dcb4" )
            ))
   "207"
   (hasheq 'install-kind 'shell-basic
           'artifacts
           (list
            (hasheq 'arch "i386" 'platform "linux" 'ext "sh" 'filename "plt-207-bin-i386-linux.sh" 'url "http://download.plt-scheme.org/bundles/207/plt/plt-207-bin-i386-linux.sh" 'sha256 "5722d74e4f5d2f06673425dd08517880d315c39c81c78fed306743c1be96d7ee" )
            ))
   "208"
   (hasheq 'install-kind 'shell-basic
           'artifacts
           (list
            (hasheq 'arch "i386" 'platform "linux" 'ext "sh" 'filename "plt-208-bin-i386-linux.sh" 'url "http://download.plt-scheme.org/bundles/208/plt/plt-208-bin-i386-linux.sh" 'sha256 "eb41db15fa8a5148b956b03a70130c13040c77d5d12699dcd0634b917b6afec6" )
            ))
   "209"
   (hasheq 'install-kind 'shell-basic
           'artifacts
           (list
            (hasheq 'arch "i386" 'platform "linux" 'ext "sh" 'filename "plt-209-bin-i386-linux.sh" 'url "http://download.plt-scheme.org/bundles/209/plt/plt-209-bin-i386-linux.sh" 'sha256 "f70696da6302a9ca22a3df1fc9c951689f07669643859768489a372c04aef5c9" )
            ))
   "300"
   (hasheq 'install-kind 'shell-basic
           'artifacts
           (list
            (hasheq 'arch "i386" 'platform "linux" 'ext "sh" 'filename "plt-300-bin-i386-linux.sh" 'url "http://download.plt-scheme.org/bundles/300/plt/plt-300-bin-i386-linux.sh" 'sha256 "36235c19bb4d834065b8bf97d07d1dc686d160bb18c2cecb1365fcc17c2ef5a2" )
            ))
   "301"
   (hasheq 'install-kind 'shell-basic
           'artifacts
           (list
            (hasheq 'arch "i386" 'platform "linux" 'ext "sh" 'filename "plt-301-bin-i386-linux.sh" 'url "http://download.plt-scheme.org/bundles/301/plt/plt-301-bin-i386-linux.sh" 'sha256 "6a6b85b34e414693cf4232c3761914049cb94c774d7a94ea60940614a641bb04" )
            ))
   "350"
   (hasheq 'install-kind 'shell-unixstyle
           'artifacts
           (list
            (hasheq 'arch "i386" 'platform "linux" 'ext "sh" 'filename "plt-350-bin-i386-linux.sh" 'url "http://download.plt-scheme.org/bundles/350/plt/plt-350-bin-i386-linux.sh" 'sha256 "3165ae053db8fc03fbb465b39e6d782b888aa5bd9a86b904606a3277674bc77e" )
            ))
   "351"
   (hasheq 'install-kind 'shell-unixstyle
           'artifacts
           (list
            (hasheq 'arch "i386" 'platform "linux" 'ext "sh" 'filename "plt-351-bin-i386-linux.sh" 'url "http://download.plt-scheme.org/bundles/351/plt/plt-351-bin-i386-linux.sh" 'sha256 "0e7a273d162dae7cef7626b134b73f04e8428c84252f64fdff81321cf47e154c" )
            ))
   "352"
   (hasheq 'install-kind 'shell-unixstyle
           'artifacts
           (list
            (hasheq 'arch "i386" 'platform "linux" 'ext "sh" 'filename "plt-352-bin-i386-linux.sh" 'url "http://download.plt-scheme.org/bundles/352/plt/plt-352-bin-i386-linux.sh" 'sha256 "2881012a55f797dc54dd2c001516dd6ce97cb4344b25293cb0802ea0f855adba" )
            ))
   "360"
   (hasheq 'install-kind 'shell-unixstyle
           'artifacts
           (list
            (hasheq 'arch "i386" 'platform "linux" 'ext "sh" 'filename "plt-360-bin-i386-linux-fc2.sh" 'url "http://download.plt-scheme.org/bundles/360/plt/plt-360-bin-i386-linux-fc2.sh" 'sha256 "4348129d674dbdf1a88a4519dfa9fea21c669c33a5343561ec1da9775e4de8a0" )
            ))
   "370"
   (hasheq 'install-kind 'shell-unixstyle
           'artifacts
           (list
            (hasheq 'arch "i386" 'platform "linux" 'ext "sh" 'filename "plt-370-bin-i386-linux-fc6.sh" 'url "http://download.plt-scheme.org/bundles/370/plt/plt-370-bin-i386-linux-fc6.sh" 'sha256 "59423400a36d18b3dc82acdfeb82675d02b55d9d6aad068103c4255a9bd1b26d" )
            ))
   "371"
   (hasheq 'install-kind 'shell-unixstyle
           'artifacts
           (list
            (hasheq 'arch "x86_64" 'platform "linux" 'ext "sh" 'filename "plt-371-bin-x86_64-linux-f7.sh" 'url "http://download.plt-scheme.org/bundles/371/plt/plt-371-bin-x86_64-linux-f7.sh" 'sha256 "43eb27434406fc6846369e994ce5c6b0ebd8b7debd3dad5f2574da622b29ed01" )
            (hasheq 'arch "i386" 'platform "linux" 'ext "sh" 'filename "plt-371-bin-i386-linux-fc6.sh" 'url "http://download.plt-scheme.org/bundles/371/plt/plt-371-bin-i386-linux-fc6.sh" 'sha256 "6413e84e2e24e018ccbac1c44e1a464daf612465f815a62fc37ecbcdcf49b6b3" )
            ))
   "372"
   (hasheq 'install-kind 'shell-unixstyle
           'artifacts
           (list
            (hasheq 'arch "x86_64" 'platform "linux" 'ext "sh" 'filename "plt-372-bin-x86_64-linux-f7.sh" 'url "http://download.plt-scheme.org/bundles/372/plt/plt-372-bin-x86_64-linux-f7.sh" 'sha256 "e1fbd756964aad7236d07cfff752075249cb7e9761cbf23de557beae904eecbb" )
            (hasheq 'arch "i386" 'platform "linux" 'ext "sh" 'filename "plt-372-bin-i386-linux-fc6.sh" 'url "http://download.plt-scheme.org/bundles/372/plt/plt-372-bin-i386-linux-fc6.sh" 'sha256 "4fd2c4277e0a7e503caa1eb30a28b2245ac14ba8b442fbf88cb929436f8b331a" )
            ))
   "4.0"
   (hasheq 'install-kind 'shell-unixstyle
           'artifacts
           (list
            (hasheq 'arch "x86_64" 'platform "linux" 'ext "sh" 'filename "plt-4.0-bin-x86_64-linux-f7.sh" 'url "http://download.plt-scheme.org/bundles/4.0/plt/plt-4.0-bin-x86_64-linux-f7.sh" 'sha256 "0c9de49ea4b22290e8bae531ee6ed6f6763b4b7b17b9df171ee9f19af183c9e1" )
            (hasheq 'arch "i386" 'platform "linux" 'ext "sh" 'filename "plt-4.0-bin-i386-linux-f9.sh" 'url "http://download.plt-scheme.org/bundles/4.0/plt/plt-4.0-bin-i386-linux-f9.sh" 'sha256 "2b74b627be600f08712a309760aeda242b5933745fefe3bcb6b509f31c9adc09" )
            ))
   "4.0.1"
   (hasheq 'install-kind 'shell-unixstyle
           'artifacts
           (list
            (hasheq 'arch "x86_64" 'platform "linux" 'ext "sh" 'filename "plt-4.0.1-bin-x86_64-linux-f7.sh" 'url "http://download.plt-scheme.org/bundles/4.0.1/plt/plt-4.0.1-bin-x86_64-linux-f7.sh" 'sha256 "aeadf35f828cdf88a1724b42b7486c507fee8471a990f1079271948179e60f69" )
            (hasheq 'arch "i386" 'platform "linux" 'ext "sh" 'filename "plt-4.0.1-bin-i386-linux-f9.sh" 'url "http://download.plt-scheme.org/bundles/4.0.1/plt/plt-4.0.1-bin-i386-linux-f9.sh" 'sha256 "806599ccc21b1708c78f45c41978e2ccb0f128d78e8422f4e382fb86a8468d71" )
            ))
   "4.0.2"
   (hasheq 'install-kind 'shell-unixstyle
           'artifacts
           (list
            (hasheq 'arch "x86_64" 'platform "linux" 'ext "sh" 'filename "plt-4.0.2-bin-x86_64-linux-f7.sh" 'url "http://download.plt-scheme.org/bundles/4.0.2/plt/plt-4.0.2-bin-x86_64-linux-f7.sh" 'sha256 "3c9856f06be1dadf1b64fce99951ce0a5f870d0da6ffe3098b79c794ef6726a9" )
            (hasheq 'arch "i386" 'platform "linux" 'ext "sh" 'filename "plt-4.0.2-bin-i386-linux-f9.sh" 'url "http://download.plt-scheme.org/bundles/4.0.2/plt/plt-4.0.2-bin-i386-linux-f9.sh" 'sha256 "deb27f6224423ed7d864b3d449526d0187dda607a15fe361cdc1cfbdb7d43e4a" )
            ))
   "4.1"
   (hasheq 'install-kind 'shell-unixstyle
           'artifacts
           (list
            (hasheq 'arch "x86_64" 'platform "linux" 'ext "sh" 'filename "plt-4.1-bin-x86_64-linux-f7.sh" 'url "http://download.plt-scheme.org/bundles/4.1/plt/plt-4.1-bin-x86_64-linux-f7.sh" 'sha256 "2d2caa93a8e84e1a883acd5534cdf63bb5589df694f487159e0941a8667be78e" )
            (hasheq 'arch "i386" 'platform "linux" 'ext "sh" 'filename "plt-4.1-bin-i386-linux-f9.sh" 'url "http://download.plt-scheme.org/bundles/4.1/plt/plt-4.1-bin-i386-linux-f9.sh" 'sha256 "35f2879b0f3722ee46647bb5b67593c08ca12f471514ad26e1dc9b77953414d8" )
            ))
   "4.1.1"
   (hasheq 'install-kind 'shell-unixstyle
           'artifacts
           (list
            (hasheq 'arch "x86_64" 'platform "linux" 'ext "sh" 'filename "plt-4.1.1-bin-x86_64-linux-f7.sh" 'url "http://download.plt-scheme.org/bundles/4.1.1/plt/plt-4.1.1-bin-x86_64-linux-f7.sh" 'sha256 "0daf245391d648db72d2312717c795c0cdc52228764a9213fa4cbda3229d91e9" )
            (hasheq 'arch "i386" 'platform "linux" 'ext "sh" 'filename "plt-4.1.1-bin-i386-linux-f9.sh" 'url "http://download.plt-scheme.org/bundles/4.1.1/plt/plt-4.1.1-bin-i386-linux-f9.sh" 'sha256 "b147467b75210a6262beb5e23c2e2d881a264dd71b6fc1444034242ae56a82c6" )
            ))
   "4.1.2"
   (hasheq 'install-kind 'shell-unixstyle
           'artifacts
           (list
            (hasheq 'arch "x86_64" 'platform "linux" 'ext "sh" 'filename "plt-4.1.2-bin-x86_64-linux-f7.sh" 'url "http://download.plt-scheme.org/bundles/4.1.2/plt/plt-4.1.2-bin-x86_64-linux-f7.sh" 'sha256 "757246b67cbd2bfaf5e076a1691db501417125fd5eeed8c24a13885ddc943dff" )
            (hasheq 'arch "i386" 'platform "linux" 'ext "sh" 'filename "plt-4.1.2-bin-i386-linux-f9.sh" 'url "http://download.plt-scheme.org/bundles/4.1.2/plt/plt-4.1.2-bin-i386-linux-f9.sh" 'sha256 "876b2a18c55e4ee76f264002871309410f333cf3c0f316a9c79fbe8b07528262" )
            ))
   "4.1.3"
   (hasheq 'install-kind 'shell-unixstyle
           'artifacts
           (list
            (hasheq 'arch "x86_64" 'platform "linux" 'ext "sh" 'filename "plt-4.1.3-bin-x86_64-linux-f7.sh" 'url "http://download.plt-scheme.org/bundles/4.1.3/plt/plt-4.1.3-bin-x86_64-linux-f7.sh" 'sha256 "66e57fe9dc610a923505e3d317edc321fccfc4209ca66c98268706bef934f30d" )
            (hasheq 'arch "i386" 'platform "linux" 'ext "sh" 'filename "plt-4.1.3-bin-i386-linux-f9.sh" 'url "http://download.plt-scheme.org/bundles/4.1.3/plt/plt-4.1.3-bin-i386-linux-f9.sh" 'sha256 "73c035d34142382bcfa1082b9a8efe98169d0959a8db351e6e1e299de119c45e" )
            ))
   "4.1.4"
   (hasheq 'install-kind 'shell-unixstyle
           'artifacts
           (list
            (hasheq 'arch "x86_64" 'platform "linux" 'ext "sh" 'filename "plt-4.1.4-bin-x86_64-linux-f7.sh" 'url "http://download.plt-scheme.org/bundles/4.1.4/plt/plt-4.1.4-bin-x86_64-linux-f7.sh" 'sha256 "bbcac181b0ec2948877108d92fc7fb6e2f3965c134d08bfb01b9f052d18a13d0" )
            (hasheq 'arch "i386" 'platform "linux" 'ext "sh" 'filename "plt-4.1.4-bin-i386-linux-f9.sh" 'url "http://download.plt-scheme.org/bundles/4.1.4/plt/plt-4.1.4-bin-i386-linux-f9.sh" 'sha256 "897918debca65492545d67075de0a0bee846b98a9f6c7bc6c226890b8249c998" )
            ))
   "4.1.5"
   (hasheq 'install-kind 'shell-unixstyle
           'artifacts
           (list
            (hasheq 'arch "x86_64" 'platform "linux" 'ext "sh" 'filename "plt-4.1.5-bin-x86_64-linux-f7.sh" 'url "http://download.plt-scheme.org/bundles/4.1.5/plt/plt-4.1.5-bin-x86_64-linux-f7.sh" 'sha256 "fe3a0d677efa563dab170724782f0ce7ca93c439edb77c9ecc68df64ef769de4" )
            (hasheq 'arch "i386" 'platform "linux" 'ext "sh" 'filename "plt-4.1.5-bin-i386-linux-f9.sh" 'url "http://download.plt-scheme.org/bundles/4.1.5/plt/plt-4.1.5-bin-i386-linux-f9.sh" 'sha256 "7d8911480517bcbdca0ed399bcd9c79787560b6739a034a3f8974baf176247d5" )
            ))
   "4.2"
   (hasheq 'install-kind 'shell-unixstyle
           'artifacts
           (list
            (hasheq 'arch "x86_64" 'platform "linux" 'ext "sh" 'filename "plt-4.2-bin-x86_64-linux-f7.sh" 'url "http://download.plt-scheme.org/bundles/4.2/plt/plt-4.2-bin-x86_64-linux-f7.sh" 'sha256 "fed7ff042276778ab5fca99cf6c235f98de497340d78fd8a2aa8d20a98f43a43" )
            (hasheq 'arch "i386" 'platform "linux" 'ext "sh" 'filename "plt-4.2-bin-i386-linux-f9.sh" 'url "http://download.plt-scheme.org/bundles/4.2/plt/plt-4.2-bin-i386-linux-f9.sh" 'sha256 "f3912f9146b8ebf2c3a7508a6fc41b6666d3580bfc80597c5b78577cd4032521" )
            ))
   "4.2.1"
   (hasheq 'install-kind 'shell-unixstyle
           'artifacts
           (list
            (hasheq 'arch "x86_64" 'platform "linux" 'ext "sh" 'filename "plt-4.2.1-bin-x86_64-linux-f7.sh" 'url "http://download.plt-scheme.org/bundles/4.2.1/plt/plt-4.2.1-bin-x86_64-linux-f7.sh" 'sha256 "52de054982e1fad063adae041c7104fd4042528f5a6279222cae8bd29423620f" )
            (hasheq 'arch "i386" 'platform "linux" 'ext "sh" 'filename "plt-4.2.1-bin-i386-linux-f9.sh" 'url "http://download.plt-scheme.org/bundles/4.2.1/plt/plt-4.2.1-bin-i386-linux-f9.sh" 'sha256 "698d990713ab928a1751d057fe4ba0c16f3ade95602968cabdb9c67f611b89fe" )
            ))
   "4.2.2"
   (hasheq 'install-kind 'shell-unixstyle
           'artifacts
           (list
            (hasheq 'arch "x86_64" 'platform "linux" 'ext "sh" 'filename "plt-4.2.2-bin-x86_64-linux-f7.sh" 'url "http://download.plt-scheme.org/bundles/4.2.2/plt/plt-4.2.2-bin-x86_64-linux-f7.sh" 'sha256 "c453e9873bf4ce16a2ddb8c8f926d38f8f378e7627a4f522e9a0c91c7739b75d" )
            (hasheq 'arch "i386" 'platform "linux" 'ext "sh" 'filename "plt-4.2.2-bin-i386-linux-f9.sh" 'url "http://download.plt-scheme.org/bundles/4.2.2/plt/plt-4.2.2-bin-i386-linux-f9.sh" 'sha256 "2ec1672036f20b40cfba929240babbd61efd16f39b5afc9132b705ea7942f761" )
            ))
   "4.2.3"
   (hasheq 'install-kind 'shell-unixstyle
           'artifacts
           (list
            (hasheq 'arch "x86_64" 'platform "linux" 'ext "sh" 'filename "plt-4.2.3-bin-x86_64-linux-f7.sh" 'url "http://download.plt-scheme.org/bundles/4.2.3/plt/plt-4.2.3-bin-x86_64-linux-f7.sh" 'sha256 "7b14b1a4935c389b5236358b9a4c70f58a266f4ec9d0d4f7de0de877d7c08db4" )
            (hasheq 'arch "i386" 'platform "linux" 'ext "sh" 'filename "plt-4.2.3-bin-i386-linux-f9.sh" 'url "http://download.plt-scheme.org/bundles/4.2.3/plt/plt-4.2.3-bin-i386-linux-f9.sh" 'sha256 "53c9dc6a6e11dd5753f005c23d18f1301dd1baf7ac424afc587cddc338be58bc" )
            ))
   "4.2.4"
   (hasheq 'install-kind 'shell-unixstyle
           'artifacts
           (list
            (hasheq 'arch "x86_64" 'platform "linux" 'ext "sh" 'filename "plt-4.2.4-bin-x86_64-linux-f7.sh" 'url "http://download.plt-scheme.org/bundles/4.2.4/plt/plt-4.2.4-bin-x86_64-linux-f7.sh" 'sha256 "fd0a63a18fe6bc57320d85c6c2b558b14cc26ed6b721968339c4c81a96be54ed" )
            (hasheq 'arch "i386" 'platform "linux" 'ext "sh" 'filename "plt-4.2.4-bin-i386-linux-f12.sh" 'url "http://download.plt-scheme.org/bundles/4.2.4/plt/plt-4.2.4-bin-i386-linux-f12.sh" 'sha256 "37dfb77c07406de77f730d25ba0312337a7d29b73d00678b87dcb4826700cbf1" )
            ))
   "4.2.5"
   (hasheq 'install-kind 'shell-unixstyle
           'artifacts
           (list
            (hasheq 'arch "x86_64" 'platform "linux" 'ext "sh" 'filename "plt-4.2.5-bin-x86_64-linux-f7.sh" 'url "http://download.plt-scheme.org/bundles/4.2.5/plt/plt-4.2.5-bin-x86_64-linux-f7.sh" 'sha256 "a9e75aaebf4eb6d74f24787f0621367b2123ec3f8f37019264cad9510e732edb" )
            (hasheq 'arch "i386" 'platform "linux" 'ext "sh" 'filename "plt-4.2.5-bin-i386-linux-f12.sh" 'url "http://download.plt-scheme.org/bundles/4.2.5/plt/plt-4.2.5-bin-i386-linux-f12.sh" 'sha256 "71cf7b465e3edceb82495cd5adb17c438c988b15024986f7bf9a269ec15239a0" )
            ))
   ))

(define (legacy-plt-version? v)
  (and (string? v) (hash-has-key? legacy-plt-release-info v)))

(define (legacy-plt-request-info version
                                 #:distribution distribution
                                 #:arch arch
                                 #:platform [platform "linux"])
  (unless (eq? distribution 'full)
    (rackup-error "PLT Scheme releases (~a) do not support --distribution ~a" version distribution))
  (unless (equal? platform "linux")
    (rackup-error "PLT Scheme releases (~a) do not support platform ~a" version platform))
  (define release (hash-ref legacy-plt-release-info version #f))
  (unless release
    (rackup-error "unknown PLT Scheme version: ~a" version))
  (define reason (hash-ref release 'reason #f))
  (when reason
    (rackup-error "~a" reason))
  (define artifacts (hash-ref release 'artifacts null))
  (define matches
    (filter (lambda (artifact)
              (and (equal? (hash-ref artifact 'arch) arch)
                   (equal? (hash-ref artifact 'platform) platform)))
            artifacts))
  (cond
    [(pair? matches)
     (define artifact (car matches))
     (hash-set artifact 'install-kind (hash-ref release 'install-kind))]
    [else
     (define supported-arches
       (remove-duplicates
        (for/list ([artifact (in-list artifacts)]
                   #:when (equal? (hash-ref artifact 'platform) platform))
          (hash-ref artifact 'arch))
        string=?))
     (define hint
       (cond
         [(and (equal? arch "x86_64") (member "i386" supported-arches))
          " (this PLT Scheme version appears to have only i386 Linux installers; try --arch i386)"]
         [(pair? supported-arches)
          (format " (supported Linux arch values: ~a)" (string-join supported-arches ", "))]
         [else ""]))
     (rackup-error "no PLT Scheme installer found for version=~a arch=~a platform=~a~a"
                   version
                   arch
                   platform
                   hint)]))
