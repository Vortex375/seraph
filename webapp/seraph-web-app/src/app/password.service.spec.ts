import { TestBed } from '@angular/core/testing';
import { provideHttpClient } from '@angular/common/http';
import { HttpTestingController, provideHttpClientTesting } from '@angular/common/http/testing';

import { PasswordService } from './password.service';

describe('PasswordService', () => {
  let service: PasswordService;
  let httpMock: HttpTestingController;

  beforeEach(() => {
    TestBed.configureTestingModule({
      providers: [provideHttpClient(), provideHttpClientTesting()],
    });
    service = TestBed.inject(PasswordService);
    httpMock = TestBed.inject(HttpTestingController);
  });

  afterEach(() => httpMock.verify());

  it('getNonce returns the nonce from the response', () => {
    let nonce: string | undefined;
    service.getNonce().subscribe(n => nonce = n);
    httpMock.expectOne('/auth/password').flush({ nonce: 'abc' });
    expect(nonce).toBe('abc');
  });
});
