package helper

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"time"
)

var ErrUnavailable = errors.New("Aster 网络组件未安装")

type Client struct{ Socket string }

func NewClient() Client {
	socket := os.Getenv("ASTER_HELPER_SOCKET")
	if socket == "" {
		socket = DefaultSocket
	}
	return Client{Socket: socket}
}

func (c Client) Installed() bool {
	_, err := os.Stat(c.Socket)
	return err == nil
}

func (c Client) Start(config []byte) (Response, error) {
	return c.call(Request{Action: "start", Config: config})
}
func (c Client) Reload(config []byte) (Response, error) {
	return c.call(Request{Action: "reload", Config: config})
}
func (c Client) Stop() (Response, error)  { return c.call(Request{Action: "stop"}) }
func (c Client) Lease() (Response, error) { return c.call(Request{Action: "lease"}) }
func (c Client) SetProxy(service string, port int, bypass []string) (Response, error) {
	return c.call(Request{Action: "set_proxy", Service: service, Port: port, Bypass: bypass})
}
func (c Client) ClearProxy(service string, port int) (Response, error) {
	return c.call(Request{Action: "clear_proxy", Service: service, Port: port})
}

func (c Client) call(request Request) (Response, error) {
	if len(request.Config) > MaxConfigSize {
		return Response{}, fmt.Errorf("核心配置超过 %d MiB 限制", MaxConfigSize>>20)
	}
	conn, err := net.DialTimeout("unix", c.Socket, 2*time.Second)
	if err != nil {
		return Response{}, fmt.Errorf("%w：请先安装 Aster 网络组件", ErrUnavailable)
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(10 * time.Second))
	if err := json.NewEncoder(conn).Encode(request); err != nil {
		return Response{}, err
	}
	var response Response
	if err := json.NewDecoder(bufio.NewReader(conn)).Decode(&response); err != nil {
		return Response{}, err
	}
	if !response.OK {
		return response, errors.New(response.Error)
	}
	return response, nil
}
