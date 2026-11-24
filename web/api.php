<?php
header("Access-Control-Allow-Origin: *");
header("Content-Type: application/json; charset=UTF-8");

$jsonFile = '../Data/stocks.json';

if (file_exists($jsonFile)) {
    $json = file_get_contents($jsonFile);
    
    // BERSIHKAN BOM (Byte Order Mark) JIKA ADA
    $bom = pack("CCC", 0xef, 0xbb, 0xbf);
    if (substr($json, 0, 3) === $bom) {
        $json = substr($json, 3);
    }
    
    // Validasi JSON
    $data = json_decode($json, true);
    if ($data === null) {
        echo json_encode(["error" => "Format JSON rusak. Cek isi file stocks.json."]);
    } else {
        echo $json;
    }
} else {
    echo json_encode(["error" => "File stocks.json tidak ditemukan di " . realpath('../Data/')]);
}
?>