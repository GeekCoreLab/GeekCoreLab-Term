const IAC: u8 = 255;
const DONT: u8 = 254;
const DO: u8 = 253;
const WONT: u8 = 252;
const WILL: u8 = 251;
const SB: u8 = 250;
const SE: u8 = 240;

const BINARY: u8 = 0;
const ECHO: u8 = 1;
const SUPPRESS_GO_AHEAD: u8 = 3;
const TERMINAL_TYPE: u8 = 24;
const NAWS: u8 = 31;
const TERMINAL_TYPE_IS: u8 = 0;
const TERMINAL_TYPE_SEND: u8 = 1;
const MAX_SUBNEGOTIATION_SIZE: usize = 4096;

#[derive(Clone, Copy)]
enum ParseState {
    Data,
    Iac,
    Negotiation(u8),
    Subnegotiation,
    SubnegotiationIac,
}

pub(crate) struct TelnetParser {
    state: ParseState,
    pending_option: Option<u8>,
    subnegotiation: Vec<u8>,
    remote_pending: [bool; 256],
    local_pending: [bool; 256],
    remote_enabled: [bool; 256],
    local_enabled: [bool; 256],
    refused_remote: [bool; 256],
    refused_local: [bool; 256],
    pending_carriage_return: bool,
}

pub(crate) struct TelnetFrame {
    pub data: Vec<u8>,
    pub replies: Vec<u8>,
    pub naws_enabled: bool,
    pub remote_binary: bool,
    pub local_binary: bool,
}

impl TelnetParser {
    pub fn new() -> Self {
        let mut remote_pending = [false; 256];
        remote_pending[BINARY as usize] = true;
        remote_pending[ECHO as usize] = true;
        remote_pending[SUPPRESS_GO_AHEAD as usize] = true;

        let mut local_pending = [false; 256];
        local_pending[BINARY as usize] = true;
        local_pending[SUPPRESS_GO_AHEAD as usize] = true;
        local_pending[TERMINAL_TYPE as usize] = true;
        local_pending[NAWS as usize] = true;

        Self {
            state: ParseState::Data,
            pending_option: None,
            subnegotiation: Vec::new(),
            remote_pending,
            local_pending,
            remote_enabled: [false; 256],
            local_enabled: [false; 256],
            refused_remote: [false; 256],
            refused_local: [false; 256],
            pending_carriage_return: false,
        }
    }

    pub fn process(&mut self, input: &[u8], cols: u16, rows: u16) -> TelnetFrame {
        let mut frame = TelnetFrame {
            data: Vec::with_capacity(input.len()),
            replies: Vec::new(),
            naws_enabled: self.local_enabled[NAWS as usize],
            remote_binary: self.remote_enabled[BINARY as usize],
            local_binary: self.local_enabled[BINARY as usize],
        };

        for byte in input.iter().copied() {
            match self.state {
                ParseState::Data => {
                    if byte == IAC {
                        self.state = ParseState::Iac;
                    } else {
                        self.push_data(byte, &mut frame.data);
                    }
                }
                ParseState::Iac => match byte {
                    IAC => {
                        self.push_data(IAC, &mut frame.data);
                        self.state = ParseState::Data;
                    }
                    WILL | WONT | DO | DONT => {
                        self.state = ParseState::Negotiation(byte);
                    }
                    SB => {
                        self.pending_option = None;
                        self.subnegotiation.clear();
                        self.state = ParseState::Subnegotiation;
                    }
                    _ => self.state = ParseState::Data,
                },
                ParseState::Negotiation(command) => {
                    self.negotiate(command, byte, cols, rows, &mut frame);
                    self.state = ParseState::Data;
                }
                ParseState::Subnegotiation => {
                    if byte == IAC {
                        self.state = ParseState::SubnegotiationIac;
                    } else if self.pending_option.is_none() {
                        self.pending_option = Some(byte);
                    } else if self.subnegotiation.len() < MAX_SUBNEGOTIATION_SIZE {
                        self.subnegotiation.push(byte);
                    }
                }
                ParseState::SubnegotiationIac => match byte {
                    SE => {
                        self.finish_subnegotiation(&mut frame.replies);
                        self.state = ParseState::Data;
                    }
                    IAC => {
                        if self.pending_option.is_some()
                            && self.subnegotiation.len() < MAX_SUBNEGOTIATION_SIZE
                        {
                            self.subnegotiation.push(IAC);
                        }
                        self.state = ParseState::Subnegotiation;
                    }
                    _ => {
                        self.state = ParseState::Subnegotiation;
                    }
                },
            }
        }

        frame.naws_enabled = self.local_enabled[NAWS as usize];
        frame.remote_binary = self.remote_enabled[BINARY as usize];
        frame.local_binary = self.local_enabled[BINARY as usize];
        frame
    }

    pub fn finish(&mut self) -> Vec<u8> {
        let mut data = Vec::new();
        if self.pending_carriage_return {
            data.push(b'\r');
            self.pending_carriage_return = false;
        }
        data
    }

    fn push_data(&mut self, byte: u8, output: &mut Vec<u8>) {
        if self.remote_enabled[BINARY as usize] {
            if self.pending_carriage_return {
                output.push(b'\r');
                self.pending_carriage_return = false;
            }
            output.push(byte);
            return;
        }
        if self.pending_carriage_return {
            output.push(b'\r');
            self.pending_carriage_return = false;
            if byte == 0 {
                return;
            }
        }
        if byte == b'\r' {
            self.pending_carriage_return = true;
        } else {
            output.push(byte);
        }
    }

    fn negotiate(
        &mut self,
        command: u8,
        option: u8,
        cols: u16,
        rows: u16,
        frame: &mut TelnetFrame,
    ) {
        let index = option as usize;
        match command {
            WILL => {
                if remote_option_supported(option) {
                    if self.remote_pending[index] {
                        self.remote_pending[index] = false;
                        self.remote_enabled[index] = true;
                    } else if !self.remote_enabled[index] {
                        push_command(&mut frame.replies, DO, option);
                        self.remote_enabled[index] = true;
                    }
                } else if !self.refused_remote[index] {
                    push_command(&mut frame.replies, DONT, option);
                    self.refused_remote[index] = true;
                }
            }
            WONT => {
                self.remote_pending[index] = false;
                self.remote_enabled[index] = false;
            }
            DO => {
                if local_option_supported(option) {
                    if self.local_pending[index] {
                        self.local_pending[index] = false;
                        self.local_enabled[index] = true;
                    } else if !self.local_enabled[index] {
                        push_command(&mut frame.replies, WILL, option);
                        self.local_enabled[index] = true;
                    }
                    if option == NAWS && self.local_enabled[index] {
                        frame.replies.extend(naws_packet(cols, rows));
                    }
                } else if !self.refused_local[index] {
                    push_command(&mut frame.replies, WONT, option);
                    self.refused_local[index] = true;
                }
            }
            DONT => {
                self.local_pending[index] = false;
                if self.local_enabled[index] {
                    self.local_enabled[index] = false;
                    push_command(&mut frame.replies, WONT, option);
                }
            }
            _ => {}
        }
    }

    fn finish_subnegotiation(&mut self, replies: &mut Vec<u8>) {
        let Some(option) = self.pending_option else {
            return;
        };
        if option == TERMINAL_TYPE
            && self.local_enabled[TERMINAL_TYPE as usize]
            && self.subnegotiation.first() == Some(&TERMINAL_TYPE_SEND)
        {
            let mut payload = vec![TERMINAL_TYPE_IS];
            payload.extend_from_slice(b"XTERM-256COLOR");
            push_subnegotiation(replies, TERMINAL_TYPE, &payload);
        }
    }
}

pub(crate) fn initial_negotiation() -> Vec<u8> {
    let mut output = Vec::with_capacity(21);
    push_command(&mut output, DO, BINARY);
    push_command(&mut output, WILL, BINARY);
    push_command(&mut output, DO, ECHO);
    push_command(&mut output, DO, SUPPRESS_GO_AHEAD);
    push_command(&mut output, WILL, SUPPRESS_GO_AHEAD);
    push_command(&mut output, WILL, TERMINAL_TYPE);
    push_command(&mut output, WILL, NAWS);
    output
}

pub(crate) fn encode_terminal_input(input: &[u8], binary: bool) -> Vec<u8> {
    let mut output = Vec::with_capacity(input.len() + 8);
    let mut index = 0;
    while index < input.len() {
        match input[index] {
            IAC => output.extend_from_slice(&[IAC, IAC]),
            b'\r' if !binary => {
                output.extend_from_slice(b"\r\n");
                if input.get(index + 1) == Some(&b'\n') {
                    index += 1;
                }
            }
            byte => output.push(byte),
        }
        index += 1;
    }
    output
}

pub(crate) fn naws_packet(cols: u16, rows: u16) -> Vec<u8> {
    let payload = [(cols >> 8) as u8, cols as u8, (rows >> 8) as u8, rows as u8];
    let mut output = Vec::with_capacity(12);
    push_subnegotiation(&mut output, NAWS, &payload);
    output
}

fn push_command(output: &mut Vec<u8>, command: u8, option: u8) {
    output.extend_from_slice(&[IAC, command, option]);
}

fn push_subnegotiation(output: &mut Vec<u8>, option: u8, payload: &[u8]) {
    output.extend_from_slice(&[IAC, SB, option]);
    for byte in payload {
        output.push(*byte);
        if *byte == IAC {
            output.push(IAC);
        }
    }
    output.extend_from_slice(&[IAC, SE]);
}

fn remote_option_supported(option: u8) -> bool {
    matches!(option, BINARY | ECHO | SUPPRESS_GO_AHEAD)
}

fn local_option_supported(option: u8) -> bool {
    matches!(option, BINARY | SUPPRESS_GO_AHEAD | TERMINAL_TYPE | NAWS)
}
