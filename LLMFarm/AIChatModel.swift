//
//  ChatViewModel.swift
//  AlpacaChatApp
//
//  Created by Yoshimasa Niwa on 3/19/23.
//

import Foundation
import SwiftUI
import os
import llmfarm_core

private extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1.0e18
    }
}

var AIChatModel_obj_ptr:UnsafeMutableRawPointer? = nil

@MainActor
final class AIChatModel: ObservableObject {
    
    enum State {
        case none
        case loading
        case completed
    }
    
    public var chat: AI?
    public var modelURL: String
    public var model_sample_param: ModelSampleParams = ModelSampleParams.default
    public var model_context_param:ModelAndContextParams = ModelAndContextParams.default
    public var numberOfTokens = 0
    public var total_sec = 0.0
    public var action_button_icon = "paperplane"
    public var model_loading = false
    public var model_name = ""
    public var chat_name = ""
    //    public var avalible_models: [String]
    public var start_predicting_time = DispatchTime.now()
    public var first_predicted_token_time = DispatchTime.now()
    public var tok_sec:Double = 0.0
    private var title_backup = ""
    
    @Published var predicting = false
    @Published var AI_typing = 0
    @Published var state: State = .none
    @Published var messages: [Message] = []
    @Published var load_progress:Float = 0.0
    @Published var Title: String = ""
    
    public init(){
        chat = nil
        modelURL = ""
    }
    
//    @MainActor
    public func load_model_by_chat_name(_ chat_name: String,in_text:String) -> Bool?{
        self.model_loading = true
        
        let chat_config = get_chat_info(chat_name)
        if (chat_config == nil){
            return nil
        }
        if (chat_config!["model_inference"] == nil || chat_config!["model"] == nil){
            return nil
        }
        
        self.model_name = chat_config!["model"] as! String
        if let m_url = get_path_by_short_name(self.model_name) {
            self.modelURL = m_url
        }else{
            return nil
        }
        
        if (self.modelURL==""){
            return nil
        }
        
        model_sample_param = ModelSampleParams.default
        model_context_param = ModelAndContextParams.default
        model_sample_param = get_model_sample_param_by_config(chat_config!)
        model_context_param = get_model_context_param_by_config(chat_config!)
        
        if (chat_config!["grammar"] != nil && chat_config!["grammar"] as! String != "<None>" && chat_config!["grammar"] as! String != ""){
            let grammar_path = get_grammar_path_by_name(chat_config!["grammar"] as! String)
            model_context_param.grammar_path = grammar_path
        }
        
        AIChatModel_obj_ptr = nil
        self.chat = nil
        self.chat = AI(_modelPath: modelURL,_chatName: chat_name);
        self.chat?.loadModel_new(model_context_param.model_inference,
            { progress in
                DispatchQueue.main.async {
                    self.load_progress = progress
//                    print(self.load_progress)
                }
                return true
            }, { load_result in
                if load_result != "[Done]"{
                    self.finish_load(append_err_msg: true, msg_text: "Load Model \(load_result)")
                    return
                }                
//                if self.chat?.model == nil || self.chat?.model.context == nil{
//                    return nil
//                }
                self.finish_load()
                self.chat?.model.sampleParams = self.model_sample_param
                self.chat?.model.contextParams = self.model_context_param
                //Set prompt model if in config or try to set promt format by filename
                
                print(self.model_sample_param)
                print(self.model_context_param)
                self.model_loading = false
                var text = in_text
                if self.model_context_param.system_prompt != ""{
                    text = self.model_context_param.system_prompt+"\n" + text
                    self.messages[self.messages.endIndex - 1].header = self.model_context_param.system_prompt
                }
                self.send(message: in_text, append_user_message:false)
            },contextParams: model_context_param)
        return true
    }
    
    
    public func stop_predict(is_error:Bool=false){
        self.chat?.flagExit = true
        self.total_sec = Double((DispatchTime.now().uptimeNanoseconds - self.start_predicting_time.uptimeNanoseconds)) / 1_000_000_000
        if messages.count>0{
            if self.messages[messages.endIndex-1].state == .predicting ||
                self.messages[messages.endIndex-1].state == .none{
                self.messages[messages.endIndex-1].state = .predicted(totalSecond: self.total_sec)
                self.messages[messages.endIndex-1].tok_sec = Double(self.numberOfTokens)/self.total_sec
            }
            if is_error{
                self.messages[messages.endIndex-1].state = .error
            }
        }
        self.predicting = false
        self.tok_sec = Double(self.numberOfTokens)/self.total_sec
        self.numberOfTokens = 0
        self.action_button_icon = "paperplane"
        self.AI_typing = 0
        save_chat_history(self.messages,self.chat_name+".json")
    }
    
    public func process_predicted_str(_ str: String, _ time: Double,_ message: inout Message, _ messageIndex: Int) -> Bool
    {
        var check = true
        for stop_word in self.model_context_param.reverse_prompt{
            if str == stop_word {
                self.stop_predict()
                check = false
                break
            }
            if message.text.hasSuffix(stop_word) {
                self.stop_predict()
                check = false
                if stop_word.count>0 && message.text.count>stop_word.count{
                    message.text.removeLast(stop_word.count)
                }
            }
        }
        if (check &&
            self.chat?.flagExit != true &&
            self.chat_name == self.chat?.chatName){
            
            message.state = .predicting
            message.text += str
            //                    self.AI_typing += str.count
            self.AI_typing += 1
            var updatedMessages = self.messages
            updatedMessages[messageIndex] = message
            self.messages = updatedMessages
            self.numberOfTokens += 1
            self.total_sec += time
            //            if (self.numberOfTokens>self.maxToken){
            //                self.stop_predict()
            //            }
        }else{
            print("chat ended.")
        }
        return check
    }
    
    public func finish_load(append_err_msg:Bool = false, msg_text:String = ""){
        if append_err_msg {
            self.messages.append(Message(sender: .system, state: .error, text: msg_text, tok_sec: 0))
            self.stop_predict(is_error: true)
        }
        self.state = .completed        
        self.Title = self.title_backup
    }

    public func send(message in_text: String, append_user_message:Bool = true)  {
        var text = in_text
        if append_user_message{
            let requestMessage = Message(sender: .user, state: .typed, text: text, tok_sec: 0)
            self.messages.append(requestMessage)
        }
        self.AI_typing += 1    
        self.load_progress = 0
        
        if self.chat != nil{
            if self.chat_name != self.chat?.chatName{
                self.chat = nil
            }
        }
        
        if self.chat == nil{
            self.state = .loading
            title_backup = Title
            Title = "loading..."
            self.load_model_by_chat_name(self.chat_name,in_text:in_text)
            return
        }
        self.state = .completed
        self.chat?.chatName = self.chat_name
        self.chat?.flagExit = false        
        var message = Message(sender: .system, text: "",tok_sec: 0)
        self.messages.append(message)
        let messageIndex = self.messages.endIndex - 1
        self.numberOfTokens = 0
        self.total_sec = 0.0
        self.predicting = true
        self.action_button_icon = "stop.circle"
        self.start_predicting_time = DispatchTime.now()
        
        self.chat?.conversation(text, 
        { str, time in //Predicting
            _ = self.process_predicted_str(str, time, &message, messageIndex)
        }, 
        { final_str in // Finish predicting            
            print(final_str)
            self.AI_typing = 0
            self.total_sec = Double((DispatchTime.now().uptimeNanoseconds - self.start_predicting_time.uptimeNanoseconds)) / 1_000_000_000
            if (self.chat_name == self.chat?.chatName && self.chat?.flagExit != true){
                message.state = .predicted(totalSecond: self.total_sec)
                if self.tok_sec != 0{
                    message.tok_sec = self.tok_sec
                }
                else{
                    message.tok_sec = Double(self.numberOfTokens)/self.total_sec
                }
                self.messages[messageIndex] = message
            }else{
                print("chat ended.")
            }
            self.predicting = false
            self.numberOfTokens = 0
            self.action_button_icon = "paperplane"
            if final_str.hasPrefix("[Error]"){
                self.messages.append(Message(sender: .system, state: .error, text: "Eval \(final_str)", tok_sec: 0))
            }
            save_chat_history(self.messages,self.chat_name+".json")
        })
    }
}
