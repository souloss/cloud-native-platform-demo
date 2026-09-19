package main

import "testing"

func TestValidateItemInput(t *testing.T) {
	tests := []struct {
		name    string
		input   itemInput
		wantErr bool
	}{
		{name: "valid", input: itemInput{Name: "Gateway API route", Description: "Portable routing contract"}},
		{name: "missing name", input: itemInput{Description: "Portable routing contract"}, wantErr: true},
		{name: "missing description", input: itemInput{Name: "Gateway API route"}, wantErr: true},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			err := validateItemInput(test.input)
			if (err != nil) != test.wantErr {
				t.Fatalf("validateItemInput() error = %v, wantErr %t", err, test.wantErr)
			}
		})
	}
}
