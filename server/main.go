package main

import (
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
)

func main() {
	// Get port from environment variable or use default
	port := os.Getenv("PORT")
	if port == "" {
		port = "3333"
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("hello world!"))
	})

	addr := fmt.Sprintf(":%s", port)
	log.Printf("server starting on port %s", port)
	if err := http.ListenAndServe(addr, mux); err != nil {
		if errors.Is(err, http.ErrServerClosed) {
			log.Println("server closed")
			return
		}

		log.Fatalf("error listening and serving: %s", err.Error())
	}
}
