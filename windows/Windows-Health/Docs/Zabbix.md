# Zabbix

Import the three Zabbix 7.0 templates from `Templates/Zabbix`.

`Windows Health` contains Update/Cleanup/Reboot.
`Windows Time` contains non-duplicate synchronization metrics.
`Microsoft Defender` contains non-duplicate antivirus health metrics.

If zabbix_sender reports `processed: 0; failed: N`, verify the Zabbix Host name matches the Windows hostname.
