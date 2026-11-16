package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"time"

	oomusic "github.com/rankgice/oo-music"
)

func main() {
	query := "周杰伦"
	if len(os.Args) > 1 {
		query = os.Args[1]
	}

	client, err := oomusic.NewClient(oomusic.WithRequestTimeout(20 * time.Second))
	if err != nil {
		log.Fatal(err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
	defer cancel()

	fmt.Fprintln(os.Stderr, "使用匿名模式")

	result, err := client.SearchSongs(ctx, query, 1, 10)
	if err != nil {
		log.Fatal(err)
	}
	if result.Code != 0 {
		log.Fatalf("QQ Music business error %d: %s", result.Code, result.Data)
	}

	var pretty any
	if err := json.Unmarshal(result.Data, &pretty); err != nil {
		log.Fatal(err)
	}
	encoded, err := json.MarshalIndent(pretty, "", "  ")
	if err != nil {
		log.Fatal(err)
	}
	fmt.Println(string(encoded))
}
