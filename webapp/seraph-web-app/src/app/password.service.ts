import { HttpClient } from '@angular/common/http';
import { Injectable } from '@angular/core';
import { map, Observable } from 'rxjs';

@Injectable({
  providedIn: 'root'
})
export class PasswordService {

  constructor(private http: HttpClient) { }

  getNonce(): Observable<string> {
    return this.http.get('/auth/password')
    .pipe(map<any, string>(v => v.nonce))
  }
}
