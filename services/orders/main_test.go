package main

import "testing"

func TestValidateOrderInput(t *testing.T) {
	tests := []struct {
		name    string
		input   orderInput
		wantErr bool
	}{
		{name: "valid", input: orderInput{ItemID: "sku-001", Quantity: 1}},
		{name: "missing item", input: orderInput{Quantity: 1}, wantErr: true},
		{name: "zero quantity", input: orderInput{ItemID: "sku-001"}, wantErr: true},
		{name: "negative quantity", input: orderInput{ItemID: "sku-001", Quantity: -1}, wantErr: true},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			err := validateOrderInput(test.input)
			if (err != nil) != test.wantErr {
				t.Fatalf("validateOrderInput() error = %v, wantErr %t", err, test.wantErr)
			}
		})
	}
}
