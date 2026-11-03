package encoding_test

import (
	"github.com/xtls/xray-core/common/buf"
	"github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/protocol"
	"github.com/xtls/xray-core/common/uuid"
	"github.com/xtls/xray-core/proxy/vless"
	. "github.com/xtls/xray-core/proxy/vless/encoding"
	"testing"
)

func TestAnyUUIDOptIn(t *testing.T) {
	for _, enabled := range []string{"", "0", "1"} {
		t.Run("enabled="+enabled, func(t *testing.T) {
			t.Setenv("XRAY_VLESS_ACCEPT_ANY_UUID", enabled)
			for i := 0; i < 3; i++ {
				id := uuid.New()
				user := &protocol.MemoryUser{Account: toAccount(&vless.Account{Id: id.String()})}
				request := &protocol.RequestHeader{Version: Version, User: user, Command: protocol.RequestCommandTCP, Address: net.DomainAddress("example.com"), Port: 443}
				buffer := buf.StackNew()
				defer buffer.Release()
				if err := EncodeRequestHeader(&buffer, request, &Addons{}); err != nil {
					t.Fatal(err)
				}
				validator := new(vless.MemoryValidator)
				_, got, _, _, err := DecodeRequestHeader(false, nil, &buffer, validator)
				if enabled != "1" {
					if err == nil {
						t.Fatal("unknown UUID accepted without opt-in")
					}
					continue
				}
				if err != nil {
					t.Fatal(err)
				}
				if !got.User.Account.(*vless.MemoryAccount).ID.Equals(protocol.NewID(id)) {
					t.Fatal("UUID was not preserved")
				}
				if len(validator.GetAll()) != 0 {
					t.Fatal("arbitrary UUID cached")
				}
			}
		})
	}
}
