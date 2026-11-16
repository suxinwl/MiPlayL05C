package signer

import "testing"

func TestKnownSignatureVectors(t *testing.T) {
	engine, err := New("")
	if err != nil {
		t.Fatal(err)
	}
	vectors := map[string]string{
		"":        "zzcf0e03e5gx4qeiq5cfgdyqwu7sdqfsb5fro3aa45053",
		"a":       "zzccf36e7d39bxosd3nqbqaaenwaoyb7jxhgse63adaf4",
		"abc":     "zzc163db6e8l6noj1uu5ylcp8kabaw6rnxos4b998e04e",
		`{"a":1}`: "zzc7746109xq501htmv4ipz7c8owlxfpihjm1fd695c7",
		`{"a":2}`: "zzc346a4d00iec9xielb9rguo3hbliijk0ug4b020001",
		`{"comm":{"ct":24},"test":{"module":"x","method":"y","param":{}}}`: "zzcf7a2664fz2lmfidqovvokqksgl8hsnrxg464474286",
	}
	for plain, want := range vectors {
		got, err := engine.Sign(plain)
		if err != nil {
			t.Fatalf("Sign(%q): %v", plain, err)
		}
		if got != want {
			t.Fatalf("Sign(%q) = %q, want %q", plain, got, want)
		}
	}
}

func TestSignerConcurrentUse(t *testing.T) {
	engine, err := New("")
	if err != nil {
		t.Fatal(err)
	}
	const plain = `{"a":1}`
	const want = "zzc7746109xq501htmv4ipz7c8owlxfpihjm1fd695c7"
	results := make(chan string, 8)
	errors := make(chan error, 8)
	for range 8 {
		go func() {
			signature, err := engine.Sign(plain)
			if err != nil {
				errors <- err
				return
			}
			results <- signature
		}()
	}
	for range 8 {
		select {
		case err := <-errors:
			t.Fatal(err)
		case got := <-results:
			if got != want {
				t.Fatalf("concurrent signature %q, want %q", got, want)
			}
		}
	}
}
