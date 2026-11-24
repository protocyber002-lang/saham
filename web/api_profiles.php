<?php
header("Access-Control-Allow-Origin: *");
header("Content-Type: application/json; charset=UTF-8");

$profileDir = '../Data/profiles/';
$profiles = [];

if (is_dir($profileDir)) {
    $files = glob($profileDir . '*.json');
    foreach ($files as $file) {
        $name = basename($file, '.json');
        // Abaikan file backup (.bak) atau file terkunci
        if (strpos($name, '.bak') !== false) { continue; }
        
        $json = file_get_contents($file);
        // Bersihkan BOM
        if (substr($json, 0, 3) === pack("CCC", 0xef, 0xbb, 0xbf)) { $json = substr($json, 3); }
        
        $data = json_decode($json, true);
        if ($data) {
            $money = isset($data['Player']['Money']) ? $data['Player']['Money'] : 0;
            $lvl = isset($data['Sectors']['Clicker']['Level']) ? $data['Sectors']['Clicker']['Level'] : 1;
            $profiles[] = [
                'Name' => $name,
                'Money' => $money,
                'Level' => $lvl
            ];
        }
    }
}
echo json_encode($profiles);
?>